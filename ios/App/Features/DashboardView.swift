import Charts
import FluxaCore
import SwiftUI

/// Le tableau de bord : l'état du réseau, les débits, la courbe en direct et les mesures.
struct DashboardView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    status
                    throughput
                    liveChart
                    LazyVGrid(columns: columns, spacing: 12) {
                        Tile("Latence", Format.milliseconds(model.snapshot.latencyMs))
                        Tile("Gigue", Format.milliseconds(model.snapshot.jitterMs))
                        Tile("Sondes sans réponse", Format.percent(model.snapshot.packetLossPercent))
                        Tile(
                            "Aujourd’hui",
                            Format.bytes(model.snapshot.receivedBytesToday + model.snapshot.sentBytesToday),
                            note: "Reçu et envoyé"
                        )
                    }
                    profile
                    NavigationLink {
                        NetworkView()
                    } label: {
                        Label("Mon réseau", systemImage: "network")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Tableau de bord")
        }
    }

    private var status: some View {
        HStack(spacing: 10) {
            if model.snapshot.isOnline {
                StatusPill(.supported, "Connecté")
            } else {
                StatusPill(.reserved, "Hors ligne")
            }
            Text(model.path.title)
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
            Spacer()
            Text(model.snapshot.isMonitoring ? "Mesure active" : "Mesure arrêtée")
                .font(.caption.monospaced())
                .foregroundStyle(Theme.tertiary)
        }
    }

    private var throughput: some View {
        let down = Format.rateParts(model.snapshot.downloadBps)
        return VStack(alignment: .leading, spacing: 6) {
            Eyebrow("Débit descendant")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(down.value)
                    .font(.system(size: 64, weight: .bold, design: .monospaced))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(Theme.down)
                    .contentTransition(.numericText())
                Text(down.unit)
                    .font(.title3.monospaced())
                    .foregroundStyle(Theme.secondary)
            }
            Text("↑ \(Format.rate(model.snapshot.uploadBps)) montant")
                .font(.subheadline.monospaced())
                .foregroundStyle(Theme.up)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var liveChart: some View {
        Card {
            if model.samples.count < 2 {
                Text("La courbe apparaît après quelques secondes de mesure.")
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                Chart {
                    ForEach(model.samples) { sample in
                        AreaMark(
                            x: .value("Heure", sample.date),
                            y: .value("Descendant", sample.downloadBps / 1_000_000)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Theme.down.opacity(0.35), Theme.down.opacity(0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        LineMark(
                            x: .value("Heure", sample.date),
                            y: .value("Débit", sample.downloadBps / 1_000_000),
                            series: .value("Sens", "Descendant")
                        )
                        .foregroundStyle(Theme.down)
                        LineMark(
                            x: .value("Heure", sample.date),
                            y: .value("Débit", sample.uploadBps / 1_000_000),
                            series: .value("Sens", "Montant")
                        )
                        .foregroundStyle(Theme.up)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(Theme.line)
                        AxisValueLabel().foregroundStyle(Theme.tertiary)
                    }
                }
                .frame(height: 140)
                .accessibilityLabel("Débits descendant et montant de la dernière minute, en mégabits par seconde")
            }
        }
    }

    private var profile: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("Profil")
                if let active = model.activeProfile {
                    HStack {
                        Text(active.name)
                            .font(.headline)
                        Spacer()
                        if let result = model.lastApply {
                            StatusPill(result.status.pill, result.status.title)
                        }
                    }
                    Text("↓ \(Format.cap(active.downloadBps)) · ↑ \(Format.cap(active.uploadBps))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                } else {
                    Text("Aucun profil choisi")
                        .font(.headline)
                    Text("Choisissez un profil dans l’onglet Profils.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
    }
}

/// Une mesure du tableau de bord.
private struct Tile: View {
    let label: String
    let value: String
    var note: String?

    init(_ label: String, _ value: String, note: String? = nil) {
        self.label = label
        self.value = value
        self.note = note
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
                Text(value)
                    .font(.title3.monospacedDigit().weight(.medium))
                    .foregroundStyle(Theme.text)
                if let note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
