import Darwin
import FluxaCore
import Foundation

/// Les compteurs d'octets des interfaces réseau, lus avec `getifaddrs`.
///
/// iOS ne donne à une app que ces compteurs, cumulés depuis le démarrage de l'appareil et
/// codés sur 32 bits. Ils comptent tout le trafic de l'interface, pas celui de chaque app
/// ni celui de chaque appareil relié au partage de connexion.
enum InterfaceCounters {
    /// Les interfaces en service, en un seul parcours : celles qui portent le trafic de
    /// l'iPhone, et le pont du partage de connexion quand il existe.
    static func read() -> [InterfaceReading] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        var readings: [InterfaceReading] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let interface = entry.pointee
            cursor = interface.ifa_next
            // Les compteurs sont portés par l'entrée de niveau liaison (AF_LINK).
            guard let address = interface.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_LINK,
                  let data = interface.ifa_data
            else { continue }
            let flags = Int32(bitPattern: interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            // Le nom est trié sur ses octets : les tunnels, AirDrop et les autres interfaces
            // écartées, chaque seconde, ne coûtent aucune chaîne Swift.
            guard let kind = classify(cName: interface.ifa_name) else { continue }
            // Le pont du partage ne compte que s'il est en service.
            guard counts(kind, isRunning: flags & IFF_RUNNING != 0) else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            readings.append(
                InterfaceReading(
                    name: String(cString: interface.ifa_name),
                    kind: kind,
                    receivedBytes: UInt64(counters.ifi_ibytes),
                    sentBytes: UInt64(counters.ifi_obytes)
                )
            )
        }
        return readings.sorted { $0.name < $1.name }
    }

    /// L'heure de démarrage de l'iPhone. Les compteurs repartent de zéro à chaque
    /// démarrage : le moteur s'en sert pour savoir si deux relevés se comparent.
    static func bootTime() -> Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.stride
        var name: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&name, 2, &time, &size, nil, 0) == 0, time.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000)
    }

    /// Si une interface de partage de connexion est en service.
    ///
    /// iOS ne dit pas à une app si le partage est actif. Quand il l'est, le système crée
    /// une interface de pont (`bridge100`) vers les appareils reliés : sa présence est un
    /// signe indirect, qui peut manquer. La règle est séparée de la lecture du système
    /// pour être testée.
    static func isSharing(_ interfaces: [(name: String, isRunning: Bool)]) -> Bool {
        interfaces.contains { classify($0.name) == .sharing && counts(.sharing, isRunning: $0.isRunning) }
    }

    /// Si une interface en service compte : le pont du partage seulement quand il tourne.
    static func counts(_ kind: InterfaceClass, isRunning: Bool) -> Bool {
        kind != .sharing || isRunning
    }

    /// La famille d'une interface d'après son nom. Les interfaces qui ne portent pas le
    /// trafic Internet de l'iPhone (tunnels, AirDrop) sont écartées, pour ne pas compter
    /// deux fois les mêmes octets. Le pont du partage a sa propre famille : le moteur le
    /// suit à part, sans l'ajouter au débit de l'iPhone.
    static func classify(_ name: String) -> InterfaceClass? {
        name.withCString { classify(cName: $0) }
    }

    /// La même règle sur le nom tel que le système le donne, sans le copier.
    static func classify(cName name: UnsafePointer<CChar>) -> InterfaceClass? {
        if strcmp(name, "en0") == 0 { return .wifi }
        if strncmp(name, "bridge10", 8) == 0 { return .sharing }
        if strncmp(name, "pdp_ip", 6) == 0 { return .cellular }
        if strncmp(name, "en", 2) == 0 { return .wired }
        return nil
    }
}
