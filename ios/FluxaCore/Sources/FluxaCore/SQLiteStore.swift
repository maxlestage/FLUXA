import Foundation

// Le stockage SQLite : le format prévu par le cahier des charges.
//
// CONTRAT : les signatures publiques de ce fichier sont utilisées par l'app.
//
// Schéma (version 2, dans `PRAGMA user_version`). Les dates sont des REAL : les secondes
// depuis la référence de Foundation (1er janvier 2001, UTC), gardées exactes. Dans le
// shell sqlite3 : `datetime(colonne + 978307200, 'unixepoch')`.
//
//   app_settings         clé, valeur : compteurs d'identifiants, profil actif, dernière réponse,
//                        forfait et son recalage, point de reprise, session de partage en cours
//   bandwidth_profiles   les profils, préréglages compris, avec leur position
//   usage_records        les agrégats ; `step` vaut minute, hour ou day
//   policy_applications  le journal des demandes de limite
//   scheduled_rules      les règles d'automatisation
//   rule_activations     les règles en cours d'effet et l'état à rendre à leur fin
//   automation_events    le journal des règles
//   speed_tests          les tests de débit
//   devices              les appareils notés par l'utilisateur
//
// Depuis la version 2 :
//
//   network_usage        le volume par réseau ; `step` vaut hour ou day
//   absences             les volumes rattrapés hors de l'app
//   sharing_sessions     les sessions de partage de connexion terminées

/// Un stockage dans une base SQLite, sur l'appareil.
///
/// Chaque famille de données a sa table (agrégats, profils, journal des limites, règles,
/// appareils, tests de débit, réglages) : un enregistrement n'écrit que les lignes qui ont
/// changé, là où le fichier JSON était réécrit en entier.
public final class SQLiteStore: EngineStore {
    /// La version du schéma que cette version de l'app sait lire et écrire.
    static let schemaVersion = 2

    private let url: URL
    private let database: SQLiteDatabase
    /// Ce que la base contient, tel que cette instance l'a lu ou écrit en dernier.
    /// `nil` : pas encore lu.
    private var known: StoredContents?
    /// Les numéros d'ordre des lignes des deux journaux, parallèles à `known`.
    private var policySequence: [Int64] = []
    private var eventSequence: [Int64] = []
    /// Le nombre de lignes écrites ou supprimées par le dernier `save`.
    private(set) var lastSaveChanges = 0
    /// Le nombre de requêtes compilées depuis l'ouverture.
    var compiledStatements: Int { database.compiledStatements }

    /// Ouvre la base, ou la crée avec son schéma. Lève `FluxaError.store` si le fichier
    /// ne peut pas être ouvert ou si son schéma est plus récent que cette version.
    public init(url: URL) throws {
        self.url = url
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw FluxaError.store("dossier de la base inaccessible (\(url.lastPathComponent)).")
        }

        var flags: Int32 = 0
        #if os(iOS)
        // SQLITE_OPEN_FILEPROTECTION_COMPLETEUNLESSOPEN : iOS chiffre la base et ses
        // fichiers annexes (-wal, -shm) quand l'iPhone est verrouillé et la base fermée.
        flags = 0x0020_0000
        #endif
        let database = try SQLiteDatabase(path: url.path, extraFlags: flags)

        // Lu avant toute écriture : un fichier qui n'est pas une base, ou une base d'une
        // version plus récente, est refusé sans être modifié.
        let version: Int
        do {
            version = Int(try database.integer("PRAGMA user_version"))
        } catch let error as FluxaError {
            guard case .store(let detail) = error else { throw error }
            throw FluxaError.store("base illisible (\(url.lastPathComponent)). \(detail)")
        }
        guard version <= Self.schemaVersion else {
            throw FluxaError.store(
                "cette base a été créée par une version plus récente de l’app "
                    + "(schéma \(version), connu : \(Self.schemaVersion)).")
        }

        // Le journal en écriture anticipée : une écriture interrompue ne laisse pas la
        // base à moitié écrite, et les lectures ne bloquent pas.
        _ = try database.rows("PRAGMA journal_mode=WAL") { $0.text(0) }
        // Avec ce journal, NORMAL ne synchronise le disque qu'aux points de contrôle et
        // non à chaque sauvegarde (une par minute) : la base reste intacte, une coupure
        // d'alimentation peut seulement perdre la dernière sauvegarde.
        try database.execute("PRAGMA synchronous=NORMAL")
        try Self.migrate(database, from: version)
        self.database = database
        protectFiles()
    }

    /// Le mode de synchronisation de la connexion (1 = NORMAL), pour les tests.
    var synchronousMode: Int64 { (try? database.integer("PRAGMA synchronous")) ?? -1 }

    // MARK: EngineStore

    public func load() throws -> EngineState? {
        let contents = try read()
        return contents.isEmpty ? nil : try contents.state()
    }

    public func save(_ state: EngineState) throws {
        let new = try StoredContents(state)
        let old = try known ?? read()
        guard new != old else {
            lastSaveChanges = 0
            return
        }
        let before = database.totalChanges
        var policySequence = self.policySequence
        var eventSequence = self.eventSequence
        try database.transaction {
            try writeSettings(old, new)
            try writeProfiles(old, new)
            try writeUsage(old, new)
            policySequence = try writePolicyLog(old, new)
            try writeRules(old, new)
            try writeActivations(old, new)
            eventSequence = try writeEvents(old, new)
            try writeSpeedTests(old, new)
            try writeDevices(old, new)
            try writeNetworkUsage(old, new)
            try writeAbsences(old, new)
            try writeSharingSessions(old, new)
        }
        // La base a accepté toute la transaction : ce qu'elle contient est connu.
        known = new
        self.policySequence = policySequence
        self.eventSequence = eventSequence
        lastSaveChanges = database.totalChanges - before
        protectFiles()
    }

    public func erase() throws {
        try database.transaction {
            for table in Self.tables {
                try database.execute("DELETE FROM \(table)")
            }
        }
        known = StoredContents()
        policySequence = []
        eventSequence = []
    }

    public var location: String? { url.path }

    /// Reprend l'état d'un ancien fichier JSON (`FileStore`) quand la base est encore vide,
    /// puis supprime ce fichier. Ne fait rien si la base contient déjà des données ou si le
    /// fichier n'existe pas ; un fichier illisible est laissé en place. Renvoie `true` si
    /// une reprise a eu lieu.
    @discardableResult
    public func importLegacyFile(at url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard try (known ?? read()).isEmpty else { return false }
        // Un fichier illisible lève ici : il reste en place, la base reste vide.
        guard let state = try FileStore(url: url).load() else { return false }
        try save(state)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw FluxaError.store(
                "données reprises, mais l’ancien fichier n’a pas pu être supprimé (\(url.lastPathComponent)).")
        }
        return true
    }

    // MARK: - Schéma

    static let tables = [
        "app_settings", "bandwidth_profiles", "usage_records", "policy_applications",
        "scheduled_rules", "rule_activations", "automation_events", "speed_tests", "devices",
        "network_usage", "absences", "sharing_sessions",
    ]

    /// Amène le schéma à la version courante. Chaque version future ajoute son étape,
    /// dans l'ordre ; tout se fait dans une transaction.
    private static func migrate(_ database: SQLiteDatabase, from version: Int) throws {
        guard version < schemaVersion else { return }
        try database.transaction {
            if version < 1 {
                try database.execute(schemaV1)
            }
            if version < 2 {
                try database.execute(schemaV2)
            }
            // if version < 3 { try database.execute(schemaV3) } …
            try database.execute("PRAGMA user_version = \(schemaVersion)")
        }
    }

    static let schemaV1 = """
        CREATE TABLE app_settings (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        ) WITHOUT ROWID;

        CREATE TABLE bandwidth_profiles (
            id           TEXT PRIMARY KEY,
            position     INTEGER NOT NULL,
            name         TEXT NOT NULL,
            download_bps INTEGER,
            upload_bps   INTEGER,
            is_builtin   INTEGER NOT NULL
        ) WITHOUT ROWID;

        CREATE TABLE usage_records (
            step              TEXT NOT NULL CHECK (step IN ('minute', 'hour', 'day')),
            start             REAL NOT NULL,
            measured_seconds  REAL NOT NULL,
            received_bytes    INTEGER NOT NULL,
            sent_bytes        INTEGER NOT NULL,
            peak_download_bps REAL NOT NULL,
            peak_upload_bps   REAL NOT NULL,
            sample_count      INTEGER NOT NULL,
            PRIMARY KEY (step, start)
        ) WITHOUT ROWID;

        CREATE TABLE policy_applications (
            seq         INTEGER PRIMARY KEY,
            decided_at  REAL NOT NULL,
            status      TEXT NOT NULL,
            capability  TEXT NOT NULL,
            result_json TEXT NOT NULL
        );

        CREATE TABLE scheduled_rules (
            id           TEXT PRIMARY KEY,
            position     INTEGER NOT NULL,
            name         TEXT NOT NULL,
            is_enabled   INTEGER NOT NULL,
            trigger_json TEXT NOT NULL,
            action_json  TEXT NOT NULL
        ) WITHOUT ROWID;

        CREATE TABLE rule_activations (
            rule_id              TEXT PRIMARY KEY,
            position             INTEGER NOT NULL,
            since                REAL NOT NULL,
            until                REAL NOT NULL,
            applied_profile_id   TEXT,
            previous_profile_id  TEXT,
            previous_result_json TEXT
        ) WITHOUT ROWID;

        CREATE TABLE automation_events (
            seq         INTEGER PRIMARY KEY,
            id          INTEGER NOT NULL,
            occurred_at REAL NOT NULL,
            rule_id     TEXT NOT NULL,
            rule_name   TEXT NOT NULL,
            kind        TEXT NOT NULL,
            message     TEXT NOT NULL
        );

        CREATE TABLE speed_tests (
            tested_at        REAL PRIMARY KEY,
            download_bps     REAL,
            upload_bps       REAL,
            latency_ms       REAL,
            network_kind     TEXT NOT NULL,
            server           TEXT NOT NULL,
            downloaded_bytes INTEGER NOT NULL,
            uploaded_bytes   INTEGER NOT NULL
        ) WITHOUT ROWID;

        CREATE TABLE devices (
            id         TEXT PRIMARY KEY,
            position   INTEGER NOT NULL,
            name       TEXT NOT NULL,
            kind       TEXT NOT NULL,
            profile_id TEXT,
            note       TEXT NOT NULL,
            added_at   REAL NOT NULL
        ) WITHOUT ROWID;
        """

    /// Version 2 : trois tables de plus. Les tables de la version 1 ne changent pas ; les
    /// réglages nouveaux sont des clés de plus dans `app_settings`.
    private static let schemaV2 = """
        CREATE TABLE network_usage (
            step           TEXT NOT NULL CHECK (step IN ('hour', 'day')),
            start          REAL NOT NULL,
            network        TEXT NOT NULL,
            received_bytes INTEGER NOT NULL,
            sent_bytes     INTEGER NOT NULL,
            PRIMARY KEY (step, start, network)
        ) WITHOUT ROWID;

        CREATE TABLE absences (
            id           INTEGER PRIMARY KEY,
            started_at   REAL NOT NULL,
            ended_at     REAL NOT NULL,
            volumes_json TEXT NOT NULL
        );

        CREATE TABLE sharing_sessions (
            id                 INTEGER PRIMARY KEY,
            started_at         REAL NOT NULL,
            ended_at           REAL NOT NULL,
            to_devices_bytes   INTEGER NOT NULL,
            from_devices_bytes INTEGER NOT NULL,
            is_lower_bound     INTEGER NOT NULL
        );
        """

    /// Sous iOS, demande aussi la protection des fichiers par leurs attributs : le
    /// drapeau d'ouverture couvre déjà la base et ses annexes, ceci vaut pour une base
    /// créée avant ce réglage. Sans effet ailleurs.
    private func protectFiles() {
        #if os(iOS)
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: path)
        }
        #endif
    }

    // MARK: - Lecture

    private func read() throws -> StoredContents {
        var contents = StoredContents()

        for (key, value) in try database.rows("SELECT key, value FROM app_settings", [], { ($0.text(0), $0.text(1)) }) {
            contents.settings[key] = value
        }

        try database.rows(
            "SELECT id, position, name, download_bps, upload_bps, is_builtin FROM bandwidth_profiles"
        ) { row in
            let profile = Profile(
                id: row.text(0), name: row.text(2), downloadBps: row.optionalUnsigned(3),
                uploadBps: row.optionalUnsigned(4), isBuiltin: row.bool(5))
            return Positioned(position: row.int(1), value: profile)
        }.forEach { contents.profiles[$0.value.id] = $0 }

        try database.rows(
            """
            SELECT step, start, measured_seconds, received_bytes, sent_bytes,
                   peak_download_bps, peak_upload_bps, sample_count FROM usage_records
            """
        ) { row -> (String, Bucket) in
            var bucket = Bucket(start: row.date(1))
            bucket.measuredSeconds = row.real(2)
            bucket.receivedBytes = row.unsigned(3)
            bucket.sentBytes = row.unsigned(4)
            bucket.peakDownloadBps = row.real(5)
            bucket.peakUploadBps = row.real(6)
            bucket.sampleCount = row.int(7)
            return (row.text(0), bucket)
        }.forEach { contents.usage[$0.0, default: []].append($0.1) }
        for step in contents.usage.keys {
            contents.usage[step]?.sort { $0.start < $1.start }
        }

        let policies = try database.rows(
            "SELECT seq, result_json FROM policy_applications ORDER BY seq"
        ) { row in (row.integer(0), try Self.decode(ApplyResult.self, row.text(1), "policy_applications")) }
        contents.policyLog = policies.map(\.1)

        try database.rows(
            "SELECT id, position, name, is_enabled, trigger_json, action_json FROM scheduled_rules"
        ) { row in
            let rule = AutomationRule(
                id: row.text(0), name: row.text(2), isEnabled: row.bool(3),
                trigger: try Self.decode(AutomationRule.Trigger.self, row.text(4), "scheduled_rules"),
                action: try Self.decode(AutomationRule.Action.self, row.text(5), "scheduled_rules"))
            return Positioned(position: row.int(1), value: rule)
        }.forEach { contents.rules[$0.value.id] = $0 }

        try database.rows(
            """
            SELECT rule_id, position, since, until, applied_profile_id, previous_profile_id,
                   previous_result_json FROM rule_activations
            """
        ) { row in
            let activation = RuleActivation(
                ruleID: row.text(0), since: row.date(2), until: row.date(3),
                appliedProfileID: row.optionalText(4), previousProfileID: row.optionalText(5),
                previousResult: try row.optionalText(6).map {
                    try Self.decode(ApplyResult.self, $0, "rule_activations")
                })
            return Positioned(position: row.int(1), value: activation)
        }.forEach { contents.activations[$0.value.ruleID] = $0 }

        let events = try database.rows(
            "SELECT seq, id, occurred_at, rule_id, rule_name, kind, message FROM automation_events ORDER BY seq"
        ) { row -> (Int64, AutomationEvent) in
            // Un genre inconnu (écrit par une version plus récente) se lit comme un début.
            let event = AutomationEvent(
                id: row.int(1), date: row.date(2), ruleID: row.text(3), ruleName: row.text(4),
                kind: AutomationEvent.Kind(rawValue: row.text(5)) ?? .started, message: row.text(6))
            return (row.integer(0), event)
        }
        contents.automationLog = events.map(\.1)

        try database.rows(
            """
            SELECT tested_at, download_bps, upload_bps, latency_ms, network_kind, server,
                   downloaded_bytes, uploaded_bytes FROM speed_tests
            """
        ) { row in
            SpeedTestResult(
                date: row.date(0), downloadBps: row.optionalReal(1), uploadBps: row.optionalReal(2),
                latencyMs: row.optionalReal(3), networkKind: NetworkKind(rawValue: row.text(4)) ?? .other,
                server: row.text(5), downloadedBytes: row.unsigned(6), uploadedBytes: row.unsigned(7))
        }.forEach { contents.speedTests[$0.date.timeIntervalSinceReferenceDate] = $0 }

        try database.rows(
            "SELECT id, position, name, kind, profile_id, note, added_at FROM devices"
        ) { row in
            let device = Device(
                id: row.text(0), name: row.text(2), kind: DeviceKind(rawValue: row.text(3)) ?? .other,
                profileID: row.optionalText(4), note: row.text(5), addedAt: row.date(6))
            return Positioned(position: row.int(1), value: device)
        }.forEach { contents.devices[$0.value.id] = $0 }

        try database.rows(
            "SELECT step, start, network, received_bytes, sent_bytes FROM network_usage"
        ) { row -> (NetworkUsageKey, NetworkBucket) in
            // Une famille inconnue (écrite par une version plus récente) se range dans « autre ».
            let kind = InterfaceClass(rawValue: row.text(2)) ?? .other
            let bucket = NetworkBucket(
                start: row.date(1), kind: kind, receivedBytes: row.unsigned(3), sentBytes: row.unsigned(4))
            return (NetworkUsageKey(step: row.text(0), start: row.real(1), network: kind.rawValue), bucket)
        }.forEach { contents.networkUsage[$0.0] = $0.1 }

        try database.rows("SELECT id, started_at, ended_at, volumes_json FROM absences") { row in
            AbsenceUsage(
                id: row.int(0), start: row.date(1), end: row.date(2),
                volumes: try Self.decode([NetworkVolume].self, row.text(3), "absences"))
        }.forEach { contents.absences[$0.id] = $0 }

        try database.rows(
            """
            SELECT id, started_at, ended_at, to_devices_bytes, from_devices_bytes, is_lower_bound
            FROM sharing_sessions
            """
        ) { row in
            SharingSession(
                id: row.int(0), start: row.date(1), end: row.date(2), toDevicesBytes: row.unsigned(3),
                fromDevicesBytes: row.unsigned(4), isLowerBound: row.bool(5))
        }.forEach { contents.sharingSessions[$0.id] = $0 }

        known = contents
        policySequence = policies.map(\.0)
        eventSequence = events.map(\.0)
        return contents
    }

    // MARK: - Écriture, famille par famille

    /// Supprime les lignes disparues, puis écrit les lignes nouvelles ou modifiées.
    private func sync<Key: Hashable, Row: Equatable>(
        _ old: [Key: Row], _ new: [Key: Row], delete: String, upsert: String,
        key: (Key) -> [SQLValue], row: (Key, Row) throws -> [SQLValue]
    ) throws {
        guard old != new else { return }
        let removed = old.keys.filter { new[$0] == nil }
        if !removed.isEmpty {
            let statement = try database.statement(delete)
            for item in removed {
                try statement.run(key(item))
            }
        }
        let changed = new.filter { old[$0.key] != $0.value }
        if !changed.isEmpty {
            let statement = try database.statement(upsert)
            for (item, value) in changed {
                try statement.run(try row(item, value))
            }
        }
    }

    /// Un journal ne fait que perdre ses plus vieilles lignes et en gagner de nouvelles :
    /// seules ces lignes sont touchées. Renvoie les numéros d'ordre des lignes restantes.
    private func syncLog<Entry: Equatable>(
        _ old: [Entry], _ sequence: [Int64], _ new: [Entry], table: String, insert: String,
        row: (Int64, Entry) throws -> [SQLValue]
    ) throws -> [Int64] {
        guard old != new else { return sequence }
        // Le plus petit nombre de vieilles lignes à retirer pour que le reste de l'ancien
        // journal soit le début du nouveau.
        var dropped = 0
        while dropped < old.count {
            let kept = old.count - dropped
            if kept <= new.count, old[dropped...].elementsEqual(new.prefix(kept)) {
                break
            }
            dropped += 1
        }
        if dropped == old.count {
            if !old.isEmpty {
                try database.execute("DELETE FROM \(table)")
            }
        } else if dropped > 0 {
            let statement = try database.statement("DELETE FROM \(table) WHERE seq = ?")
            for seq in sequence.prefix(dropped) {
                try statement.run([.integer(seq)])
            }
        }
        var remaining = Array(sequence.dropFirst(dropped))
        let added = new.dropFirst(old.count - dropped)
        if !added.isEmpty {
            let statement = try database.statement(insert)
            var next = (sequence.last ?? 0) + 1
            for entry in added {
                try statement.run(try row(next, entry))
                remaining.append(next)
                next += 1
            }
        }
        return remaining
    }

    private func writeSettings(_ old: StoredContents, _ new: StoredContents) throws {
        try sync(
            old.settings, new.settings,
            delete: "DELETE FROM app_settings WHERE key = ?",
            upsert: """
                INSERT INTO app_settings (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
            key: { [.text($0)] },
            row: { [.text($0), .text($1)] })
    }

    private func writeProfiles(_ old: StoredContents, _ new: StoredContents) throws {
        try sync(
            old.profiles, new.profiles,
            delete: "DELETE FROM bandwidth_profiles WHERE id = ?",
            upsert: """
                INSERT INTO bandwidth_profiles (id, position, name, download_bps, upload_bps, is_builtin)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET position = excluded.position, name = excluded.name,
                    download_bps = excluded.download_bps, upload_bps = excluded.upload_bps,
                    is_builtin = excluded.is_builtin
                """,
            key: { [.text($0)] },
            row: { id, item in
                let profile = item.value
                return [
                    .text(id), .integer(item.position), .text(profile.name),
                    .optionalUnsigned(profile.downloadBps), .optionalUnsigned(profile.uploadBps),
                    .bool(profile.isBuiltin),
                ]
            })
    }

    private func writeUsage(_ old: StoredContents, _ new: StoredContents) throws {
        guard old.usage != new.usage else { return }
        let delete = "DELETE FROM usage_records WHERE step = ? AND start = ?"
        let upsert = """
            INSERT INTO usage_records (step, start, measured_seconds, received_bytes, sent_bytes,
                peak_download_bps, peak_upload_bps, sample_count)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(step, start) DO UPDATE SET measured_seconds = excluded.measured_seconds,
                received_bytes = excluded.received_bytes, sent_bytes = excluded.sent_bytes,
                peak_download_bps = excluded.peak_download_bps,
                peak_upload_bps = excluded.peak_upload_bps, sample_count = excluded.sample_count
            """
        for step in Set(old.usage.keys).union(new.usage.keys) {
            let changes = Self.changes(from: old.usage[step] ?? [], to: new.usage[step] ?? [])
            if !changes.removed.isEmpty {
                let statement = try database.statement(delete)
                for start in changes.removed {
                    try statement.run([.text(step), .date(start)])
                }
            }
            if !changes.changed.isEmpty {
                let statement = try database.statement(upsert)
                for bucket in changes.changed {
                    try statement.run([
                        .text(step), .date(bucket.start), .real(bucket.measuredSeconds),
                        .unsigned(bucket.receivedBytes), .unsigned(bucket.sentBytes),
                        .real(bucket.peakDownloadBps), .real(bucket.peakUploadBps),
                        .integer(bucket.sampleCount),
                    ])
                }
            }
        }
    }

    /// Ce qui sépare deux suites triées par début, d'un seul parcours des deux : les débuts
    /// disparus, et les périodes nouvelles ou modifiées.
    static func changes(from old: [Bucket], to new: [Bucket]) -> (removed: [Date], changed: [Bucket]) {
        var removed: [Date] = []
        var changed: [Bucket] = []
        var (i, j) = (0, 0)
        while i < old.count || j < new.count {
            if j == new.count || (i < old.count && old[i].start < new[j].start) {
                removed.append(old[i].start)
                i += 1
            } else if i == old.count || new[j].start < old[i].start {
                changed.append(new[j])
                j += 1
            } else {
                if old[i] != new[j] {
                    changed.append(new[j])
                }
                i += 1
                j += 1
            }
        }
        return (removed, changed)
    }

    private func writePolicyLog(_ old: StoredContents, _ new: StoredContents) throws -> [Int64] {
        try syncLog(
            old.policyLog, policySequence, new.policyLog, table: "policy_applications",
            insert: """
                INSERT INTO policy_applications (seq, decided_at, status, capability, result_json)
                VALUES (?, ?, ?, ?, ?)
                """,
            row: { seq, result in
                [
                    .integer(seq), .date(result.date), .text(result.status.rawValue),
                    .text(result.capability.rawValue), .text(try Self.encode(result)),
                ]
            })
    }

    private func writeRules(_ old: StoredContents, _ new: StoredContents) throws {
        try sync(
            old.rules, new.rules,
            delete: "DELETE FROM scheduled_rules WHERE id = ?",
            upsert: """
                INSERT INTO scheduled_rules (id, position, name, is_enabled, trigger_json, action_json)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET position = excluded.position, name = excluded.name,
                    is_enabled = excluded.is_enabled, trigger_json = excluded.trigger_json,
                    action_json = excluded.action_json
                """,
            key: { [.text($0)] },
            row: { id, item in
                let rule = item.value
                return [
                    .text(id), .integer(item.position), .text(rule.name), .bool(rule.isEnabled),
                    .text(try Self.encode(rule.trigger)), .text(try Self.encode(rule.action)),
                ]
            })
    }

    private func writeActivations(_ old: StoredContents, _ new: StoredContents) throws {
        try sync(
            old.activations, new.activations,
            delete: "DELETE FROM rule_activations WHERE rule_id = ?",
            upsert: """
                INSERT INTO rule_activations (rule_id, position, since, until, applied_profile_id,
                    previous_profile_id, previous_result_json)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(rule_id) DO UPDATE SET position = excluded.position, since = excluded.since,
                    until = excluded.until, applied_profile_id = excluded.applied_profile_id,
                    previous_profile_id = excluded.previous_profile_id,
                    previous_result_json = excluded.previous_result_json
                """,
            key: { [.text($0)] },
            row: { id, item in
                let activation = item.value
                return [
                    .text(id), .integer(item.position), .date(activation.since), .date(activation.until),
                    .optionalText(activation.appliedProfileID), .optionalText(activation.previousProfileID),
                    .optionalText(try activation.previousResult.map(Self.encode)),
                ]
            })
    }

    private func writeEvents(_ old: StoredContents, _ new: StoredContents) throws -> [Int64] {
        try syncLog(
            old.automationLog, eventSequence, new.automationLog, table: "automation_events",
            insert: """
                INSERT INTO automation_events (seq, id, occurred_at, rule_id, rule_name, kind, message)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            row: { seq, event in
                [
                    .integer(seq), .integer(event.id), .date(event.date), .text(event.ruleID),
                    .text(event.ruleName), .text(event.kind.rawValue), .text(event.message),
                ]
            })
    }

    private func writeSpeedTests(_ old: StoredContents, _ new: StoredContents) throws {
        try sync(
            old.speedTests, new.speedTests,
            delete: "DELETE FROM speed_tests WHERE tested_at = ?",
            upsert: """
                INSERT INTO speed_tests (tested_at, download_bps, upload_bps, latency_ms, network_kind,
                    server, downloaded_bytes, uploaded_bytes)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(tested_at) DO UPDATE SET download_bps = excluded.download_bps,
                    upload_bps = excluded.upload_bps, latency_ms = excluded.latency_ms,
                    network_kind = excluded.network_kind, server = excluded.server,
                    downloaded_bytes = excluded.downloaded_bytes, uploaded_bytes = excluded.uploaded_bytes
                """,
            key: { [.real($0)] },
            row: { date, test in
                [
                    .real(date), .optionalReal(test.downloadBps), .optionalReal(test.uploadBps),
                    .optionalReal(test.latencyMs), .text(test.networkKind.rawValue), .text(test.server),
                    .unsigned(test.downloadedBytes), .unsigned(test.uploadedBytes),
                ]
            })
    }

    private func writeDevices(_ old: StoredContents, _ new: StoredContents) throws {
        try sync(
            old.devices, new.devices,
            delete: "DELETE FROM devices WHERE id = ?",
            upsert: """
                INSERT INTO devices (id, position, name, kind, profile_id, note, added_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET position = excluded.position, name = excluded.name,
                    kind = excluded.kind, profile_id = excluded.profile_id, note = excluded.note,
                    added_at = excluded.added_at
                """,
            key: { [.text($0)] },
            row: { id, item in
                let device = item.value
                return [
                    .text(id), .integer(item.position), .text(device.name), .text(device.kind.rawValue),
                    .optionalText(device.profileID), .text(device.note), .date(device.addedAt),
                ]
            })
    }

    private func writeNetworkUsage(_ old: StoredContents, _ new: StoredContents) throws {
        try sync(
            old.networkUsage, new.networkUsage,
            delete: "DELETE FROM network_usage WHERE step = ? AND start = ? AND network = ?",
            upsert: """
                INSERT INTO network_usage (step, start, network, received_bytes, sent_bytes)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(step, start, network) DO UPDATE SET
                    received_bytes = excluded.received_bytes, sent_bytes = excluded.sent_bytes
                """,
            key: { [.text($0.step), .real($0.start), .text($0.network)] },
            row: { key, bucket in
                [
                    .text(key.step), .real(key.start), .text(key.network),
                    .unsigned(bucket.receivedBytes), .unsigned(bucket.sentBytes),
                ]
            })
    }

    private func writeAbsences(_ old: StoredContents, _ new: StoredContents) throws {
        try sync(
            old.absences, new.absences,
            delete: "DELETE FROM absences WHERE id = ?",
            upsert: """
                INSERT INTO absences (id, started_at, ended_at, volumes_json) VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET started_at = excluded.started_at,
                    ended_at = excluded.ended_at, volumes_json = excluded.volumes_json
                """,
            key: { [.integer($0)] },
            row: { id, absence in
                [
                    .integer(id), .date(absence.start), .date(absence.end),
                    .text(try Self.encode(absence.volumes)),
                ]
            })
    }

    private func writeSharingSessions(_ old: StoredContents, _ new: StoredContents) throws {
        try sync(
            old.sharingSessions, new.sharingSessions,
            delete: "DELETE FROM sharing_sessions WHERE id = ?",
            upsert: """
                INSERT INTO sharing_sessions (id, started_at, ended_at, to_devices_bytes,
                    from_devices_bytes, is_lower_bound)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET started_at = excluded.started_at,
                    ended_at = excluded.ended_at, to_devices_bytes = excluded.to_devices_bytes,
                    from_devices_bytes = excluded.from_devices_bytes,
                    is_lower_bound = excluded.is_lower_bound
                """,
            key: { [.integer($0)] },
            row: { id, session in
                [
                    .integer(id), .date(session.start), .date(session.end),
                    .unsigned(session.toDevicesBytes), .unsigned(session.fromDevicesBytes),
                    .bool(session.isLowerBound),
                ]
            })
    }

    // MARK: - JSON des colonnes riches

    fileprivate static func encode<Value: Encodable>(_ value: Value) throws -> String {
        do {
            // Clés triées : la même valeur donne toujours le même texte, et un réglage
            // inchangé n'est pas réécrit.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        } catch {
            throw FluxaError.store("donnée impossible à enregistrer.")
        }
    }

    fileprivate static func decode<Value: Decodable>(_ type: Value.Type, _ text: String, _ table: String) throws
        -> Value
    {
        do {
            return try JSONDecoder().decode(type, from: Data(text.utf8))
        } catch {
            throw FluxaError.store("ligne illisible dans la table \(table).")
        }
    }
}

// MARK: - Le contenu de la base

/// Une ligne et sa place dans une liste ordonnée.
struct Positioned<Value: Equatable>: Equatable {
    var position: Int
    var value: Value
}

/// La clé d'un volume par réseau : son pas, son début et la famille d'interfaces.
struct NetworkUsageKey: Hashable {
    var step: String
    var start: Double
    var network: String
}

/// Le contenu de la base, famille par famille, tel qu'il se compare ligne à ligne.
struct StoredContents: Equatable {
    var settings: [String: String] = [:]
    var profiles: [String: Positioned<Profile>] = [:]
    /// Les agrégats, par pas (`minute`, `hour`, `day`), triés par début : les suites mêmes
    /// du moteur, gardées sans copie. Un enregistrement les compare d'un seul parcours, au
    /// lieu de ranger chaque période, jusqu'à 11 000, dans une table à clés.
    var usage: [String: [Bucket]] = [:]
    var policyLog: [ApplyResult] = []
    var rules: [String: Positioned<AutomationRule>] = [:]
    var activations: [String: Positioned<RuleActivation>] = [:]
    var automationLog: [AutomationEvent] = []
    var speedTests: [Double: SpeedTestResult] = [:]
    var devices: [String: Positioned<Device>] = [:]
    var networkUsage: [NetworkUsageKey: NetworkBucket] = [:]
    /// Les absences et les sessions de partage, par identifiant : leur ordre est celui
    /// de leurs identifiants.
    var absences: [Int: AbsenceUsage] = [:]
    var sharingSessions: [Int: SharingSession] = [:]

    init() {}

    var isEmpty: Bool { self == StoredContents() }

    private enum Setting {
        static let version = "state_version"
        static let nextProfileNumber = "next_profile_number"
        static let nextRuleNumber = "next_rule_number"
        static let nextAutomationEventID = "next_automation_event_id"
        static let nextDeviceNumber = "next_device_number"
        static let activeProfileID = "active_profile_id"
        static let lastApplyResult = "last_apply_result"
        static let nextAbsenceID = "next_absence_id"
        static let nextSharingSessionID = "next_sharing_session_id"
        static let dataPlan = "data_plan"
        static let planCalibration = "plan_calibration"
        static let checkpoint = "counter_checkpoint"
        static let currentSharing = "current_sharing_session"
    }

    /// Range un état dans les familles de la base.
    init(_ state: EngineState) throws {
        settings[Setting.version] = String(state.version)
        settings[Setting.nextProfileNumber] = String(state.nextProfileNumber)
        settings[Setting.nextRuleNumber] = String(state.nextRuleNumber)
        settings[Setting.nextAutomationEventID] = String(state.nextAutomationEventID)
        settings[Setting.nextDeviceNumber] = String(state.nextDeviceNumber)
        settings[Setting.activeProfileID] = state.activeProfileID
        settings[Setting.lastApplyResult] = try state.lastApplyResult.map(SQLiteStore.encode)
        settings[Setting.nextAbsenceID] = String(state.nextAbsenceID)
        settings[Setting.nextSharingSessionID] = String(state.nextSharingSessionID)
        settings[Setting.dataPlan] = try state.dataPlan.map(SQLiteStore.encode)
        settings[Setting.planCalibration] = try state.planCalibration.map(SQLiteStore.encode)
        settings[Setting.checkpoint] = try state.checkpoint.map(SQLiteStore.encode)
        settings[Setting.currentSharing] = try state.currentSharing.map(SQLiteStore.encode)

        profiles = Self.positioned(state.profiles, id: \.id)
        rules = Self.positioned(state.rules, id: \.id)
        activations = Self.positioned(state.activations, id: \.ruleID)
        devices = Self.positioned(state.devices, id: \.id)
        policyLog = state.policyLog
        automationLog = state.automationLog

        let series: [(HistoryStep, BucketSeries)] = [
            (.minute, state.minutes), (.hour, state.hours), (.day, state.days),
        ]
        for (step, buckets) in series where buckets.count > 0 {
            usage[step.rawValue] = buckets.buckets
        }
        let networks: [(HistoryStep, NetworkSeries)] = [(.hour, state.networkHours), (.day, state.networkDays)]
        for (step, series) in networks {
            for bucket in series.buckets {
                let key = NetworkUsageKey(
                    step: step.rawValue, start: bucket.start.timeIntervalSinceReferenceDate,
                    network: bucket.kind.rawValue)
                networkUsage[key] = bucket
            }
        }
        // Un identifiant en double garde sa première occurrence.
        for absence in state.absences where absences[absence.id] == nil {
            absences[absence.id] = absence
        }
        for session in state.sharingSessions where sharingSessions[session.id] == nil {
            sharingSessions[session.id] = session
        }
        // La date identifie un test : en cas de doublon, le premier de la liste reste.
        for test in state.speedTests {
            let key = test.date.timeIntervalSinceReferenceDate
            if speedTests[key] == nil {
                speedTests[key] = test
            }
        }
    }

    /// Les éléments d'une liste, chacun avec sa place. Un identifiant en double garde
    /// sa première occurrence.
    private static func positioned<Value: Equatable>(_ values: [Value], id: KeyPath<Value, String>)
        -> [String: Positioned<Value>]
    {
        var result: [String: Positioned<Value>] = [:]
        for value in values where result[value[keyPath: id]] == nil {
            result[value[keyPath: id]] = Positioned(position: result.count, value: value)
        }
        return result
    }

    private static func ordered<Value: Equatable>(_ rows: [String: Positioned<Value>]) -> [Value] {
        rows.values.sorted { $0.position < $1.position }.map(\.value)
    }

    /// Reconstruit l'état à partir des familles de la base.
    func state() throws -> EngineState {
        var state = EngineState()
        let number = { (key: String, fallback: Int) in settings[key].flatMap(Int.init) ?? fallback }
        guard number(Setting.version, EngineState.currentVersion) <= EngineState.currentVersion else {
            throw FluxaError.store("données d’un format plus récent que cette version de l’app.")
        }
        // L'état lu sera réécrit avec les champs de cette version.
        state.version = EngineState.currentVersion
        state.nextProfileNumber = number(Setting.nextProfileNumber, 1)
        state.nextRuleNumber = number(Setting.nextRuleNumber, 1)
        state.nextAutomationEventID = number(Setting.nextAutomationEventID, 1)
        state.nextDeviceNumber = number(Setting.nextDeviceNumber, 1)
        state.activeProfileID = settings[Setting.activeProfileID]
        state.lastApplyResult = try settings[Setting.lastApplyResult].map {
            try SQLiteStore.decode(ApplyResult.self, $0, "app_settings")
        }

        state.profiles = Self.ordered(profiles)
        state.rules = Self.ordered(rules)
        state.activations = Self.ordered(activations)
        state.devices = Self.ordered(devices)
        state.policyLog = policyLog
        state.automationLog = automationLog
        state.speedTests = speedTests.values.sorted { $0.date > $1.date }

        let buckets = { (step: HistoryStep) in
            BucketSeries(buckets: usage[step.rawValue] ?? [])
        }
        state.minutes = buckets(.minute)
        state.hours = buckets(.hour)
        state.days = buckets(.day)

        state.nextAbsenceID = number(Setting.nextAbsenceID, 1)
        state.nextSharingSessionID = number(Setting.nextSharingSessionID, 1)
        state.dataPlan = try settings[Setting.dataPlan].map {
            try SQLiteStore.decode(DataPlan.self, $0, "app_settings")
        }
        state.planCalibration = try settings[Setting.planCalibration].map {
            try SQLiteStore.decode(PlanCalibration.self, $0, "app_settings")
        }
        state.checkpoint = try settings[Setting.checkpoint].map {
            try SQLiteStore.decode(CounterCheckpoint.self, $0, "app_settings")
        }
        state.currentSharing = try settings[Setting.currentSharing].map {
            try SQLiteStore.decode(SharingSession.self, $0, "app_settings")
        }
        let networks = { (step: HistoryStep) in
            NetworkSeries(buckets: networkUsage.filter { $0.key.step == step.rawValue }.map(\.value))
        }
        state.networkHours = networks(.hour)
        state.networkDays = networks(.day)
        state.absences = absences.values.sorted { $0.id < $1.id }
        state.sharingSessions = sharingSessions.values.sorted { $0.id < $1.id }
        return state
    }
}
