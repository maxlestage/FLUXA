import FluxaCore
import SwiftUI

/// Les crédits : qui a créé FLUXA, et ce sur quoi l'app s'appuie.
struct CreditsView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("FLUXA")
                        .font(.title2.weight(.heavy))
                        .foregroundStyle(Theme.down)
                    Text(AppInfo.versionLine)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                }
                .padding(.vertical, 4)
                LabeledContent("Création") {
                    Text(AppInfo.author)
                        .multilineTextAlignment(.trailing)
                }
                .accessibilityIdentifier("credit-auteur")
            } header: {
                Text("Crédits")
            }

            Section {
                ValueRow("Interface", "SwiftUI, Swift Charts")
                ValueRow("Moteur", "FluxaCore \(FluxaEngine.version), Swift")
                ValueRow("Relais", "fluxa-shaper \(KernelShaper.version), Rust")
                ValueRow("Base", "SQLite")
            } header: {
                Text("Construite avec")
            } footer: {
                Text("Le relais s’appuie sur la crate Rust libc (licences MIT ou Apache 2.0). Le reste vient des bibliothèques d’Apple et de SQLite, dans le domaine public.")
            }
        }
        .fluxaBackground()
        .navigationTitle("Crédits")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// L'identité de l'app : version, numéro de build, auteur.
enum AppInfo {
    static let author = "Maxime Nathan Lestage"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? Format.missing
    }

    /// Le numéro de build : celui de l'envoi sur TestFlight.
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? Format.missing
    }

    /// « Version 1.0 (build 12) ».
    static var versionLine: String {
        line(version: version, build: build)
    }

    static func line(version: String, build: String) -> String {
        "Version \(version) (build \(build))"
    }
}
