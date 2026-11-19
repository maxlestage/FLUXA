import Darwin
import FluxaCore
import Foundation

/// Les compteurs d'octets des interfaces réseau, lus avec `getifaddrs`.
///
/// iOS ne donne à une app que ces compteurs, cumulés depuis le démarrage de l'appareil et
/// codés sur 32 bits. Ils comptent tout le trafic de l'interface, pas celui de chaque app
/// ni celui de chaque appareil relié au partage de connexion.
enum InterfaceCounters {
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
            let name = String(cString: interface.ifa_name)
            guard let kind = classify(name) else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            readings.append(
                InterfaceReading(
                    name: name,
                    kind: kind,
                    receivedBytes: UInt64(counters.ifi_ibytes),
                    sentBytes: UInt64(counters.ifi_obytes)
                )
            )
        }
        return readings.sorted { $0.name < $1.name }
    }

    /// La famille d'une interface d'après son nom. Les interfaces qui ne portent pas le
    /// trafic Internet de l'iPhone (tunnels, AirDrop, pont du partage) sont écartées, pour
    /// ne pas compter deux fois les mêmes octets.
    static func classify(_ name: String) -> InterfaceClass? {
        if name == "en0" { return .wifi }
        if name.hasPrefix("pdp_ip") { return .cellular }
        if name.hasPrefix("en") { return .wired }
        return nil
    }
}
