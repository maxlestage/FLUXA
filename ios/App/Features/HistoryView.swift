import Charts
import FluxaCore
import SwiftUI

/// L'historique : le débit et la consommation sur une heure, un jour ou un mois.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var period = Period.hour

    enum Period: String, CaseIterable, Identifiable {
        case hour, day, month

        var id: String { rawValue }

        var title: String {
            switch self {
            case .hour: "1 heure"
            case .day: "24 heures"
            case .month: "30 jours"
            }
        }

        var step: HistoryStep {
            switch self {
            case .hour: .minute
            case .day: .hour
            case .month: .day
            }
        }

        var unit: Calendar.Component {
            switch self {
            case .hour: .minute
            case .day: .hour
            case .month: .day
            }
        }

        var interval: TimeInterval {
            switch self {
            case .hour: 3_600
            case .day: 86_400
            case .month: 30 * 86_400
            }
        }
    }

    var body: some View {
        // L'écran se relit quand l'historique change.
        let _ = model.historyRevision
        let now = Date()
        let start = now.addingTimeInterval(-period.interval)
        let aggregates = model.history(from: start, to: now, step: period.step)
        let usage = model.usage(from: start, to: now)

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Période", selection: $period) {
                        ForEach(Period.allCases) { period in
                            Text(period.title).tag(period)
                        }
                    }
                    .pickerStyle(.segmented)

                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Eyebrow("Débit moyen, en Mb/s")
                            if aggregates.isEmpty {
                                ContentUnavailableView(
                                    "Pas encore d’historique",
                                    systemImage: "chart.bar.xaxis",
                                    description: Text("Les mesures sont regroupées à la fin de chaque minute, quand l’app est au premier plan.")
                                )
                            } else {
                                chart(aggregates)
                                HStack(spacing: 16) {
                                    Legend(color: Theme.down, label: "Descendant")
                                    Legend(color: Theme.up, label: "Montant")
                                }
                            }
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Eyebrow("Bilan de la période")
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                                SummaryRow("Reçu", Format.bytes(usage.receivedBytes))
                                SummaryRow("Envoyé", Format.bytes(usage.sentBytes))
                                SummaryRow("Débit descendant moyen", Format.rate(usage.averageDownloadBps))
                                SummaryRow("Pic descendant", Format.rate(usage.peakDownloadBps))
                                SummaryRow("Débit montant moyen", Format.rate(usage.averageUploadBps))
                                SummaryRow("Pic montant", Format.rate(usage.peakUploadBps))
                            }
                        }
                    }

                    Text("Conservation : 7 jours pour les minutes, 30 jours pour les heures, 12 mois pour les jours.")
                        .font(.footnote)
                        .foregroundStyle(Theme.tertiary)
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Historique")
        }
    }

    private func chart(_ aggregates: [Aggregate]) -> some View {
        Chart {
            ForEach(aggregates) { aggregate in
                BarMark(
                    x: .value("Début", aggregate.start, unit: period.unit),
                    y: .value("Descendant", aggregate.averageDownloadBps / 1_000_000)
                )
                .foregroundStyle(Theme.down)
                LineMark(
                    x: .value("Début", aggregate.start, unit: period.unit),
                    y: .value("Montant", aggregate.averageUploadBps / 1_000_000)
                )
                .foregroundStyle(Theme.up)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel().foregroundStyle(Theme.tertiary)
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel().foregroundStyle(Theme.tertiary)
            }
        }
        .frame(height: 200)
        .accessibilityLabel("Débit moyen descendant et montant sur la période")
    }
}

private struct Legend: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.secondary)
        }
    }
}

private struct SummaryRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(Theme.secondary)
            Text(value)
                .font(.body.monospacedDigit())
                .gridColumnAlignment(.trailing)
        }
    }
}
