import FluxaCore
import SwiftUI

/// Le limiteur : régler un plafond, voir son effet simulé, l'enregistrer, et tenter de
/// l'appliquer au partage de connexion par le module Rust `fluxa-shaper`. Le statut ne
/// passe à « Appliqué » que si le système confirme une règle posée : sur iPhone, il
/// reste « Simulé ».
struct LimiterView: View {
    @Environment(AppModel.self) private var model

    @State private var limitsDownload = true
    @State private var downloadPosition = LimiterView.position(forMbps: 25)
    @State private var limitsUpload = true
    @State private var uploadPosition = LimiterView.position(forMbps: 10)
    @State private var mode = LimitMode.hardLimit
    @State private var duration = Span.unlimited
    @State private var attempt: KernelShaper.Report?
    @State private var attemptFailed = false

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
        // La simulation porte sur le débit du moment : l'écran la refait à chaque relevé.
        let _ = model.snapshot
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
                Button {
                    attempt = KernelShaper.tryApply(
                        BandwidthPolicyRates(downloadBps: policy.downloadBps, uploadBps: policy.uploadBps))
                    attemptFailed = attempt == nil
                } label: {
                    Label("Tenter d’appliquer au partage", systemImage: "bolt.horizontal")
                }
                .disabled(problem != nil)
                .accessibilityIdentifier("tenter-application")
                if let attempt {
                    ForEach(attempt.attempts) { step in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(step.title)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 12)
                                StatusPill(LimiterView.pill(for: step.outcome), LimiterView.title(for: step.outcome))
                            }
                            Text(step.message)
                                .font(.footnote)
                                .foregroundStyle(Theme.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    LabeledContent("Interface du partage") {
                        Text(attempt.sharingInterface ?? "Absente")
                            .font(.body.monospaced())
                    }
                    Text(attempt.summary)
                        .font(.footnote)
                        .foregroundStyle(attempt.applied ? Theme.ok : Theme.reserved)
                        .accessibilityIdentifier("bilan-tentative")
                }
                if attemptFailed {
                    Text("Le module de tentative n’a pas répondu.")
                        .font(.footnote)
                        .foregroundStyle(Theme.reserved)
                }
            } header: {
                Text("Tentative auprès d’iOS")
            } footer: {
                Text("FLUXA essaie les mécanismes du noyau qui brident le réseau (pf, dummynet, sysctl) et affiche la réponse du système à chacun. Le plafond n’est annoncé appliqué que si le système confirme une règle posée.")
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

    static func pill(for outcome: KernelShaper.Report.Attempt.Outcome) -> StatusPill.Kind {
        switch outcome {
        case .accepted: .supported
        case .refused: .reserved
        case .missing: .guide
        }
    }

    static func title(for outcome: KernelShaper.Report.Attempt.Outcome) -> String {
        switch outcome {
        case .accepted: "Accordé"
        case .refused: "Refusé"
        case .missing: "Absent"
        }
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
