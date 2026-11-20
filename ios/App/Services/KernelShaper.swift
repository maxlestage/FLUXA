import FluxaShaper
import Foundation

/// La tentative d'application d'un plafond au partage de connexion, faite par le module
/// Rust `fluxa-shaper` (ios/Shaper) à travers son ABI C.
///
/// Le module essaie les mécanismes du noyau qui brident le réseau et rapporte la réponse
/// du système à chacun. Il ne déclare jamais un plafond appliqué sans règle posée et
/// confirmée : sur un iPhone, le bac à sable des apps refuse ces mécanismes.
enum KernelShaper {
    struct Report: Decodable, Equatable {
        struct Attempt: Decodable, Equatable, Identifiable {
            enum Outcome: String, Decodable {
                case accepted, refused, missing
            }

            let mechanism: String
            let title: String
            let outcome: Outcome
            let code: String?
            let message: String

            var id: String { mechanism }
        }

        let version: String
        let downloadBps: UInt64?
        let uploadBps: UInt64?
        let sharingInterface: String?
        let applied: Bool
        let systemAllows: Bool
        let summary: String
        let attempts: [Attempt]
    }

    /// Le rapport du module, ou `nil` s'il est illisible.
    static func tryApply(_ policy: BandwidthPolicyRates) -> Report? {
        guard let pointer = fluxa_shaper_try_apply(policy.downloadBps ?? 0, policy.uploadBps ?? 0) else {
            return nil
        }
        defer { fluxa_shaper_free(pointer) }
        return decode(String(cString: pointer))
    }

    static func decode(_ json: String) -> Report? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(Report.self, from: Data(json.utf8))
    }

    static var version: String {
        String(cString: fluxa_shaper_version())
    }
}

/// Les deux plafonds d'une limite, en bits par seconde.
struct BandwidthPolicyRates {
    let downloadBps: UInt64?
    let uploadBps: UInt64?
}
