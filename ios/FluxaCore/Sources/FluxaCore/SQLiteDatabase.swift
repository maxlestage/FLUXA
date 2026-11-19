import Foundation

#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

// Une enveloppe mince autour de l'API C de SQLite : ouverture, requêtes préparées,
// transactions. Toute erreur devient `FluxaError.store` avec le message de SQLite.

/// Une valeur liée à une requête préparée.
enum SQLValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    static func integer(_ value: Int) -> SQLValue { .integer(Int64(value)) }
    /// Un entier non signé, gardé bit pour bit : SQLite ne connaît que les entiers signés.
    static func unsigned(_ value: UInt64) -> SQLValue { .integer(Int64(bitPattern: value)) }
    static func optionalUnsigned(_ value: UInt64?) -> SQLValue { value.map(unsigned) ?? .null }
    static func optionalReal(_ value: Double?) -> SQLValue { value.map(SQLValue.real) ?? .null }
    static func optionalText(_ value: String?) -> SQLValue { value.map(SQLValue.text) ?? .null }
    static func bool(_ value: Bool) -> SQLValue { .integer(value ? 1 : 0) }
    /// Une date exacte : les secondes depuis la référence de Foundation (1er janvier 2001, UTC).
    static func date(_ value: Date) -> SQLValue { .real(value.timeIntervalSinceReferenceDate) }
}

/// Une connexion à une base SQLite. S'utilise depuis un seul fil d'exécution.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    let path: String

    /// Ouvre la base, ou la crée. `extraFlags` s'ajoute à lecture, écriture et création.
    init(path: String, extraFlags: Int32 = 0) throws {
        self.path = path
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | extraFlags
        let code = sqlite3_open_v2(path, &connection, flags, nil)
        guard code == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(code)"
            sqlite3_close(connection)
            throw FluxaError.store("ouverture de la base impossible : \(message).")
        }
        handle = connection
    }

    deinit {
        sqlite3_close(handle)
    }

    fileprivate var connection: OpaquePointer? { handle }

    fileprivate func failure(_ context: String) -> FluxaError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "base fermée"
        return FluxaError.store("\(context) : \(message).")
    }

    /// Exécute du SQL sans valeur liée : schéma, transactions, réglages.
    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw failure("requête refusée par la base")
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        try SQLiteStatement(database: self, sql: sql)
    }

    /// Lit toutes les lignes d'une requête.
    func rows<T>(_ sql: String, _ values: [SQLValue] = [], _ read: (SQLiteStatement) throws -> T) throws
        -> [T]
    {
        let statement = try prepare(sql)
        try statement.bind(values)
        var result: [T] = []
        while try statement.step() {
            result.append(try read(statement))
        }
        return result
    }

    /// Le premier entier renvoyé par une requête.
    func integer(_ sql: String) throws -> Int64 {
        try rows(sql) { $0.integer(0) }.first ?? 0
    }

    /// Le nombre de lignes insérées, modifiées ou supprimées depuis l'ouverture.
    var totalChanges: Int { Int(sqlite3_total_changes(handle)) }

    /// Tout ou rien : si `body` lève, rien de ce qu'il a écrit ne reste dans la base.
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

/// Une requête préparée, réutilisable : on lie des valeurs, on exécute, on recommence.
final class SQLiteStatement {
    private let database: SQLiteDatabase
    private var handle: OpaquePointer?

    fileprivate init(database: SQLiteDatabase, sql: String) throws {
        self.database = database
        guard sqlite3_prepare_v2(database.connection, sql, -1, &handle, nil) == SQLITE_OK else {
            throw database.failure("requête refusée par la base")
        }
    }

    deinit {
        sqlite3_finalize(handle)
    }

    func bind(_ values: [SQLValue]) throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        // SQLite copie le texte : il peut disparaître après l'appel.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null: code = sqlite3_bind_null(handle, index)
            case .integer(let integer): code = sqlite3_bind_int64(handle, index, integer)
            case .real(let real): code = sqlite3_bind_double(handle, index, real)
            case .text(let text): code = sqlite3_bind_text(handle, index, text, -1, transient)
            }
            guard code == SQLITE_OK else {
                throw database.failure("valeur refusée par la base")
            }
        }
    }

    /// Avance d'une ligne. `false` : la requête est terminée.
    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw database.failure("écriture ou lecture refusée par la base")
        }
    }

    /// Lie les valeurs et exécute la requête jusqu'au bout.
    func run(_ values: [SQLValue] = []) throws {
        try bind(values)
        while try step() {}
        sqlite3_reset(handle)
    }

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }
    func integer(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(handle, column)) }
    func unsigned(_ column: Int32) -> UInt64 { UInt64(bitPattern: sqlite3_column_int64(handle, column)) }
    func optionalUnsigned(_ column: Int32) -> UInt64? { isNull(column) ? nil : unsigned(column) }
    func real(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
    func optionalReal(_ column: Int32) -> Double? { isNull(column) ? nil : real(column) }
    func bool(_ column: Int32) -> Bool { integer(column) != 0 }
    func date(_ column: Int32) -> Date { Date(timeIntervalSinceReferenceDate: real(column)) }

    func text(_ column: Int32) -> String {
        sqlite3_column_text(handle, column).map { String(cString: $0) } ?? ""
    }

    func optionalText(_ column: Int32) -> String? { isNull(column) ? nil : text(column) }
}
