import FluxaCore
import Foundation
import Observation

/// Le test de débit : il télécharge puis envoie des données de test pendant quelques
/// secondes, sur plusieurs connexions, et mesure le débit obtenu.
///
/// Le serveur doit offrir deux adresses : `GET /__down?bytes=N`, qui renvoie N octets, et
/// `POST /__up`, qui accepte un corps quelconque. C'est le cas de speed.cloudflare.com,
/// le serveur par défaut.
@MainActor
@Observable
final class SpeedTestRunner {
    enum Phase: Equatable {
        case idle, latency, download, upload, finished
        case failed(String)

        var isRunning: Bool {
            self == .latency || self == .download || self == .upload
        }
    }

    static let defaultServer = "https://speed.cloudflare.com"

    /// Un test court (`-fluxaShortSpeedTest YES` au lancement) : les tests automatiques
    /// vérifient le déroulement sans transférer des centaines de mégaoctets à chaque fois.
    nonisolated static let isShort = UserDefaults.standard.bool(forKey: "fluxaShortSpeedTest")

    private(set) var phase = Phase.idle
    /// Le débit de la phase en cours, mis à jour pendant le transfert.
    private(set) var liveBps: Double?
    private(set) var downloadBps: Double?
    private(set) var uploadBps: Double?
    private(set) var latencyMs: Double?
    /// Les octets transférés par le test, dans les deux sens.
    private(set) var transferredBytes: UInt64 = 0

    private var running: Task<Void, Never>?

    /// Lance un test. `onFinish` reçoit le résultat quand au moins une phase a abouti.
    func start(server: String, networkKind: NetworkKind, onFinish: @escaping (SpeedTestResult) -> Void) {
        guard !phase.isRunning else { return }
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URL(string: trimmed), let host = base.host, base.scheme == "https" else {
            phase = .failed("L’adresse du serveur de test doit commencer par https://.")
            return
        }
        liveBps = nil
        downloadBps = nil
        uploadBps = nil
        latencyMs = nil
        transferredBytes = 0
        running = Task { [weak self] in
            guard let self else { return }
            self.phase = .latency
            self.latencyMs = await Self.latency(host: host)
            if Task.isCancelled { return self.reset() }

            self.phase = .download
            let download = await self.transfer(.download, base: base)
            self.downloadBps = download.bps
            if Task.isCancelled { return self.reset() }

            self.phase = .upload
            self.liveBps = nil
            let upload = await self.transfer(.upload, base: base)
            self.uploadBps = upload.bps
            if Task.isCancelled { return self.reset() }

            self.liveBps = nil
            guard download.bps != nil || upload.bps != nil else {
                self.phase = .failed("Le serveur de test n’a pas répondu. Vérifiez la connexion, ou l’adresse du serveur dans les réglages.")
                return
            }
            self.phase = .finished
            onFinish(
                SpeedTestResult(
                    date: Date(),
                    downloadBps: download.bps,
                    uploadBps: upload.bps,
                    latencyMs: self.latencyMs,
                    networkKind: networkKind,
                    server: host,
                    downloadedBytes: download.bytes,
                    uploadedBytes: upload.bytes
                )
            )
        }
    }

    func cancel() {
        running?.cancel()
        running = nil
        reset()
    }

    private func reset() {
        phase = .idle
        liveBps = nil
    }

    /// La plus courte de trois sondes : la première compte aussi la résolution du nom.
    private static func latency(host: String) async -> Double? {
        var best: Double?
        for _ in 0..<3 {
            if let value = await LatencyProbe.measure(host: host, timeout: 2) {
                best = min(best ?? value, value)
            }
        }
        return best
    }

    private enum Direction {
        case download, upload

        /// Les connexions ouvertes en parallèle.
        var connections: Int { self == .download ? 4 : 3 }

        var duration: TimeInterval {
            if SpeedTestRunner.isShort { return self == .download ? 3 : 2 }
            return self == .download ? 8 : 6
        }

        /// Le volume au-delà duquel la phase s'arrête, pour borner la consommation.
        var byteLimit: UInt64 {
            if SpeedTestRunner.isShort { return self == .download ? 20_000_000 : 8_000_000 }
            return self == .download ? 200_000_000 : 60_000_000
        }
    }

    private func transfer(_ direction: Direction, base: URL) async -> (bps: Double?, bytes: UInt64) {
        let counter = TransferCounter(budget: TransferBudget(limit: direction.byteLimit))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.httpMaximumConnectionsPerHost = 8
        let session = URLSession(configuration: configuration, delegate: counter, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let body = direction == .upload ? Self.testData(megabytes: 4) : Data()
        let launch: @Sendable () -> Void = { [weak session] in
            guard let session else { return }
            switch direction {
            case .download:
                // 50 Mo par requête ; une requête terminée est relancée.
                guard let url = Self.endpoint(base, "__down?bytes=50000000") else { return }
                session.dataTask(with: URLRequest(url: url)).resume()
            case .upload:
                guard let url = Self.endpoint(base, "__up") else { return }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                session.uploadTask(with: request, from: body).resume()
            }
        }
        // Un transfert terminé est relancé : le débit se mesure sur toute la durée. Le volume
        // annoncé atteint, les transferts s'arrêtent aussitôt, sans attendre le relevé suivant.
        counter.onSuccess = launch
        counter.onBudgetSpent = { [weak session] in session?.invalidateAndCancel() }
        for _ in 0..<direction.connections {
            launch()
        }

        var meter = SpeedMeter()
        let started = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
            let elapsed = Date().timeIntervalSince(started)
            meter.add(bytes: counter.take(), at: elapsed)
            liveBps = meter.bps(at: elapsed)
            if elapsed >= direction.duration || meter.totalBytes >= direction.byteLimit || counter.budgetSpent {
                break
            }
            // Toutes les connexions ont échoué sans rien transférer : inutile d'attendre.
            if meter.totalBytes == 0, counter.failures >= direction.connections {
                break
            }
        }
        counter.onSuccess = nil
        counter.onBudgetSpent = nil
        // Les octets arrivés depuis le dernier relevé comptent dans le volume, pas dans le débit.
        let volume = meter.totalBytes + UInt64(max(counter.take(), 0))
        transferredBytes += volume
        return (meter.finalBps, volume)
    }

    /// Un bloc d'octets aléatoires, tiré par mots de 64 bits : un tirage par 8 octets, et
    /// non un tirage par octet qui en jetterait 7. Mesuré sous Linux, en version optimisée :
    /// 2,5 ms par bloc de 64 Ko au lieu de 20.
    nonisolated static func randomBlock(bytes: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var words = [UInt64](repeating: 0, count: (bytes + 7) / 8)
        for index in words.indices {
            words[index] = generator.next()
        }
        return words.withUnsafeBytes { Data($0.prefix(bytes)) }
    }

    /// L'adresse d'un point d'entrée du serveur de test.
    nonisolated static func endpoint(_ base: URL, _ path: String) -> URL? {
        let root = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: root + "/" + path)
    }

    /// Des données de test : un bloc aléatoire répété.
    nonisolated static func testData(megabytes: Int) -> Data {
        let block = randomBlock(bytes: 65_536)
        var data = Data(capacity: megabytes * 1_048_576)
        for _ in 0..<(megabytes * 16) {
            data.append(block)
        }
        return data
    }
}

/// Le volume qu'une phase du test peut transférer. Il est compté à chaque morceau reçu ou
/// envoyé, et non au relevé suivant (toutes les 200 ms) : à 1 Gb/s, 200 ms font 25 Mo de
/// plus que le volume annoncé. Le dépassement se borne au morceau qui l'atteint.
struct TransferBudget: Equatable {
    let limit: UInt64
    private(set) var spent: UInt64 = 0

    init(limit: UInt64) {
        self.limit = limit
    }

    /// Compte un morceau. `false` : le volume est atteint, les transferts doivent cesser.
    mutating func spend(_ bytes: Int) -> Bool {
        let (sum, overflow) = spent.addingReportingOverflow(UInt64(max(bytes, 0)))
        spent = overflow ? .max : sum
        return spent < limit
    }
}

/// Compte les octets reçus et envoyés par les transferts d'une session.
private final class TransferCounter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0
    private var failed = 0
    private var restart: (@Sendable () -> Void)?
    private var budget: TransferBudget
    private var spentAll = false
    private var stop: (@Sendable () -> Void)?

    init(budget: TransferBudget) {
        self.budget = budget
    }

    /// Appelé une fois, quand le volume de la phase est atteint.
    var onBudgetSpent: (@Sendable () -> Void)? {
        get { lock.withLock { stop } }
        set { lock.withLock { stop = newValue } }
    }

    var budgetSpent: Bool {
        lock.withLock { spentAll }
    }

    /// Compte des octets ; le volume atteint, arrête la session une seule fois.
    private func count(_ bytes: Int) {
        let stopNow: (@Sendable () -> Void)? = lock.withLock {
            pending += bytes
            guard !spentAll, !budget.spend(bytes) else { return nil }
            spentAll = true
            return stop
        }
        stopNow?()
    }

    /// Appelé quand un transfert se termine sans erreur.
    var onSuccess: (@Sendable () -> Void)? {
        get { lock.withLock { restart } }
        set { lock.withLock { restart = newValue } }
    }

    var failures: Int {
        lock.withLock { failed }
    }

    /// Les octets comptés depuis le dernier appel.
    func take() -> Int {
        lock.withLock {
            let bytes = pending
            pending = 0
            return bytes
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        // Une réponse d'erreur du serveur n'est pas un débit.
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Seul le téléchargement compte les octets reçus : la réponse à un envoi est minuscule.
        guard dataTask.originalRequest?.httpMethod != "POST" else { return }
        count(data.count)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        count(Int(bytesSent))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error == nil, !budgetSpent {
            onSuccess?()
        } else {
            lock.withLock { failed += 1 }
        }
    }
}
