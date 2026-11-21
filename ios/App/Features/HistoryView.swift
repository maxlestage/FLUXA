import Accessibility
import Charts
import CoreTransferable
import FluxaCore
import SwiftUI
import UniformTypeIdentifiers

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
        let comparison = model.compareUsage(from: start, to: now)
        let usage = comparison.current
        // Le volume par réseau est gardé à l'heure et au jour : pas de détail sur une heure.
        let networks = period == .hour ? [] : model.usageByNetwork(from: start, to: now)
        let absences = Array(model.absences(limit: 50).filter { $0.end >= start }.prefix(5))

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

                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Eyebrow("Par rapport à la période précédente")
                            Text(Self.change(comparison))
                                .font(.title3.monospacedDigit().weight(.semibold))
                                .foregroundStyle(Theme.text)
                            Text(Self.previousDetail(comparison))
                                .font(.footnote)
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("comparaison")

                    if !networks.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: 12) {
                                Eyebrow("Par réseau")
                                ForEach(networks) { network in
                                    NetworkShare(usage: network, largest: networks.first?.totalBytes ?? 0)
                                }
                                if networks.contains(where: { $0.outsideAppBytes > 0 }) {
                                    Text("« Hors de l’app » : rattrapé d’après les compteurs du système à votre retour. C’est un minimum.")
                                        .font(.footnote)
                                        .foregroundStyle(Theme.tertiary)
                                }
                            }
                        }
                        // Un conteneur à part entière : sans lui, l'identifiant se
                        // répandrait sur chaque ligne du bloc.
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("par-reseau")
                    }

                    if !absences.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: 12) {
                                Eyebrow("Hors de l’app")
                                ForEach(absences) { absence in
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(Format.dateTime(absence.end))
                                            Spacer()
                                            Text(Format.span(absence.duration))
                                                .font(.callout.monospacedDigit())
                                                .foregroundStyle(Theme.tertiary)
                                        }
                                        Text(PlanText.atLeast(absence.totalBytes))
                                            .font(.subheadline.monospacedDigit())
                                            .foregroundStyle(Theme.secondary)
                                    }
                                    .accessibilityElement(children: .combine)
                                }
                                Text("Ce que les compteurs du système ont vu passer pendant que FLUXA ne mesurait pas, relevé à chaque retour.")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.tertiary)
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("absences")
                    }

                    Text("Conservation : 7 jours pour les minutes, 30 jours pour les heures, 12 mois pour les jours.")
                        .font(.footnote)
                        .foregroundStyle(Theme.tertiary)
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Historique")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(
                        item: HistoryExport(csv: model.exportCSV(from: start, to: now, step: period.step)),
                        preview: SharePreview("Historique FLUXA, \(period.title)")
                    ) {
                        Label("Exporter", systemImage: "square.and.arrow.up")
                    }
                    .disabled(aggregates.isEmpty)
                }
            }
        }
    }

    /// La variation du volume, en une phrase.
    static func change(_ comparison: UsageComparison) -> String {
        guard let percent = comparison.changePercent else {
            return "Rien à comparer"
        }
        let rounded = percent.rounded()
        if rounded == 0 {
            return "Volume stable"
        }
        let sign = rounded > 0 ? "+" : "−"
        return "\(sign)\(Format.number(abs(rounded), digits: 0))\u{00A0}% de volume"
    }

    static func previousDetail(_ comparison: UsageComparison) -> String {
        guard comparison.changePercent != nil else {
            return "La période précédente n’a pas de mesure."
        }
        let before = comparison.previous.receivedBytes + comparison.previous.sentBytes
        let now = comparison.current.receivedBytes + comparison.current.sentBytes
        return "\(Format.bytes(now)) sur cette période, \(Format.bytes(before)) sur la précédente."
    }

    /// La part d'un volume dans le plus gros, entre 0 et 1.
    static func share(_ bytes: UInt64, of largest: UInt64) -> Double {
        largest == 0 ? 0 : min(1, Double(bytes) / Double(largest))
    }

    /// « ↓ 1,20 Go · ↑ 80,0 Mo », et la part rattrapée hors de l'app s'il y en a une.
    static func detail(_ usage: NetworkUsage) -> String {
        var text = "↓ \(Format.bytes(usage.receivedBytes)) · ↑ \(Format.bytes(usage.sentBytes))"
        if usage.outsideAppBytes > 0 {
            text += " · dont au moins \(Format.bytes(usage.outsideAppBytes)) hors de l’app"
        }
        return text
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
        .accessibilityValue(Self.chartSummary(aggregates))
        .accessibilityChartDescriptor(HistoryChartDescriptor(aggregates: aggregates, summary: Self.chartSummary(aggregates)))
    }

    /// Ce que VoiceOver dit du graphique : moyenne et pic de chaque sens, comme le bilan
    /// de la période. La moyenne pondère chaque intervalle par son nombre de mesures.
    static func chartSummary(_ aggregates: [Aggregate]) -> String {
        let measured = aggregates.filter { $0.sampleCount > 0 }
        guard !measured.isEmpty else { return "Aucune mesure sur la période." }
        let samples = Double(measured.reduce(0) { $0 + $1.sampleCount })
        func average(_ value: (Aggregate) -> Double) -> Double {
            measured.reduce(0.0) { $0 + value($1) * Double($1.sampleCount) } / samples
        }
        let download = average { $0.averageDownloadBps }
        let upload = average { $0.averageUploadBps }
        let peakDownload = measured.map { $0.peakDownloadBps }.max() ?? 0
        let peakUpload = measured.map { $0.peakUploadBps }.max() ?? 0
        return "Descendant : \(Format.rate(download)) en moyenne, pic à \(Format.rate(peakDownload)). "
            + "Montant : \(Format.rate(upload)) en moyenne, pic à \(Format.rate(peakUpload))."
    }
}

/// Le graphique de l'historique pour les graphiques audio de VoiceOver : un point par
/// intervalle, débit moyen descendant (barres) et montant (ligne), en Mb/s.
private struct HistoryChartDescriptor: AXChartDescriptorRepresentable {
    let aggregates: [Aggregate]
    let summary: String

    func makeChartDescriptor() -> AXChartDescriptor {
        let times = aggregates.map { $0.start.timeIntervalSince1970 }
        let first = times.min() ?? 0
        let last = max(times.max() ?? 1, first)
        let xAxis = AXNumericDataAxisDescriptor(
            title: "Heure", range: first...last, gridlinePositions: []
        ) { value in
            Date(timeIntervalSince1970: value).formatted(date: .abbreviated, time: .shortened)
        }
        let highest = aggregates.map { max($0.averageDownloadBps, $0.averageUploadBps) }.max() ?? 0
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Débit", range: 0...max(highest / 1_000_000, 1), gridlinePositions: []
        ) { value in
            Format.rate(value * 1_000_000)
        }
        let download = AXDataSeriesDescriptor(
            name: "Descendant", isContinuous: false,
            dataPoints: aggregates.map { AXDataPoint(x: $0.start.timeIntervalSince1970, y: $0.averageDownloadBps / 1_000_000) }
        )
        let upload = AXDataSeriesDescriptor(
            name: "Montant", isContinuous: true,
            dataPoints: aggregates.map { AXDataPoint(x: $0.start.timeIntervalSince1970, y: $0.averageUploadBps / 1_000_000) }
        )
        return AXChartDescriptor(
            title: "Débit moyen sur la période", summary: summary,
            xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: [download, upload]
        )
    }
}

/// Le volume d'un réseau sur la période, avec une barre à l'échelle du plus gros.
private struct NetworkShare: View {
    let usage: NetworkUsage
    let largest: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(usage.kind.title)
                Spacer()
                Text(Format.bytes(usage.totalBytes))
                    .font(.body.monospacedDigit())
            }
            ProgressView(value: HistoryView.share(usage.totalBytes, of: largest))
                .tint(usage.kind == .cellular ? Theme.up : Theme.down)
            Text(HistoryView.detail(usage))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.secondary)
        }
        .accessibilityElement(children: .combine)
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

/// L'historique exporté : un fichier CSV, lisible par un tableur.
struct HistoryExport: Transferable {
    let csv: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { export in
            Data(export.csv.utf8)
        }
        .suggestedFileName("fluxa-historique.csv")
    }
}
