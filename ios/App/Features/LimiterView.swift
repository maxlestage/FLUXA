import FluxaCore
import SwiftUI

/// Le limiteur : régler un plafond, voir son effet simulé, l'enregistrer. Sur iPhone,
/// le statut reste « Simulé » : rien n'est appliqué au partage de connexion.
struct LimiterView: View {
    @Environment(AppModel.self) private var model

    @State private var limitsDownload = true
    @State private var downloadPosition = LimiterView.position(forMbps: 25)
    @State private var limitsUpload = true
    @State private var uploadPosition = LimiterView.position(forMbps: 10)
    @State private var mode = LimitMode.hardLimit
    @State private var duration = Span.unlimited

    /// Les durées proposées, d'une minute à sans limite de temps.
    enum Span: UInt64, CaseIterable, Identifiable {
        case oneMinute = 60
        case quarterHour = 900
        case oneHour = 3_600
        case eightHours = 28_800
        case unlimited = 0

        var id: UInt64 { rawValue }
        var seconds: UInt64? { self == .unlimited ? nil : rawValue }
        var title: String { Format.duration(seconds: seconds) }
    }

    private var policy: BandwidthPolicy {
        BandwidthPolicy(
            downloadBps: limitsDownload ? Limits.bps(fromMbps: Self.mbps(at: downloadPosition)) : nil,
            uploadBps: limitsUpload ? Limits.bps(fromMbps: Self.mbps(at: uploadPosition)) : nil,
            mode: mode,
            durationSeconds: duration.seconds
        )
    }

    var body: some View {
        let policy = self.policy
        let simulation = model.simulate(policy)
        let problem = model.problem(with: policy)

        Form {
            Section {
                Toggle("Plafond descendant", isOn: $limitsDownload)
                if limitsDownload {
                    RateSlider(position: $downloadPosition, color: Theme.down)
                }
                Toggle("Plafond montant", isOn: $limitsUpload)
                if limitsUpload {
                    RateSlider(position: $uploadPosition, color: Theme.up)
                }
            } header: {
                Text("Plafonds")
            } footer: {
                Text("Échelle logarithmique, de 0,1 à 1 000 Mb/s.")
            }

            Section("Réglages") {
                Picker("Mode", selection: $mode) {
                    ForEach(LimitMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("Durée", selection: $duration) {
                    ForEach(Span.allCases) { duration in
                        Text(duration.title).tag(duration)
                    }
                }
            }

            Section {
                EffectRow(label: "Descendant", effect: simulation.download, color: Theme.down)
                EffectRow(label: "Montant", effect: simulation.upload, color: Theme.up)
            } header: {
                Text("Effet simulé sur le débit mesuré")
            } footer: {
                Text("Un plafond ne peut que réduire un débit : au-dessus du débit mesuré, il est sans effet.")
            }

            Section {
                LabeledContent("Enregistré dans FLUXA") {
                    StatusPill(.supported, "Configuré")
                }
                LabeledContent("Appliqué au partage") {
                    StatusPill(.reserved, "Réservé à iOS")
                }
                LabeledContent("Statut affiché") {
                    StatusPill(.simulated, "Simulé")
                }
            } header: {
                Text("Ce que fait l’iPhone")
            }

            Section {
                Button("Enregistrer la limite") {
                    model.apply(policy)
                }
                .disabled(problem != nil)
                if let problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(Theme.reserved)
                }
                if let result = model.lastApply, result.requested == policy, let reason = result.reason {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
        .fluxaBackground()
        .navigationTitle("Limiteur de débit")
        .navigationBarTitleDisplayMode(.inline)
    }

    // L'échelle des curseurs : 0 vaut 0,1 Mb/s, 1 vaut 1 000 Mb/s, en progression logarithmique.

    static func mbps(at position: Double) -> Double {
        let value = 0.1 * pow(10_000, min(max(position, 0), 1))
        // Un plafond se règle avec au plus deux chiffres significatifs.
        let magnitude = pow(10, floor(log10(value)) - 1)
        return (value / magnitude).rounded() * magnitude
    }

    static func position(forMbps mbps: Double) -> Double {
        log10(min(max(mbps, 0.1), 1_000) / 0.1) / 4
    }
}

private struct RateSlider: View {
    @Binding var position: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Format.cap(Limits.bps(fromMbps: LimiterView.mbps(at: position))))
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
            Slider(value: $position, in: 0...1) {
                Text("Plafond")
            } minimumValueLabel: {
                Text("0,1").font(.caption2.monospaced())
            } maximumValueLabel: {
                Text("1 000").font(.caption2.monospaced())
            }
            .tint(color)
        }
    }
}

private struct EffectRow: View {
    let label: String
    let effect: DirectionEffect?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
            if let effect {
                if effect.isReduced {
                    Text("\(Format.rate(effect.measuredBps)) → \(Format.rate(effect.resultBps))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(color)
                } else if effect.capBps == nil {
                    Text("\(Format.rate(effect.measuredBps)), sans plafond")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                } else {
                    Text("\(Format.rate(effect.measuredBps)), sous le plafond")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                }
            } else {
                Text("Pas encore de débit mesuré")
                    .font(.subheadline)
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
