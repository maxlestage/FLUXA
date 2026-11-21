import Charts
import FluxaCore
import SwiftUI

/// Le tableau de bord : l'état du réseau, les débits, la courbe en direct et les mesures.
///
/// Chaque bloc est une vue à part qui lit elle-même ce dont elle a besoin : une mesure
/// qui change chaque seconde ne redessine que son bloc, pas tout l'écran.
struct DashboardView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    StatusLine()
                    ThroughputHeader()
                    LiveChart()
                    MeasureTiles()
                    AbsenceCard()
                    PlanCard()
                    SharingCard()
                    ProfileCard()
                    NavigationLink {
                        SpeedTestView()
                    } label: {
                        Label("Tester le débit", systemImage: "speedometer")
                            .foregroundStyle(Theme.background)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
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
}

private struct StatusLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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
}

private struct ThroughputHeader: View {
    @Environment(AppModel.self) private var model
    /// Le grand débit suit la taille de texte choisie dans les réglages d'iOS.
    @ScaledMetric(relativeTo: .largeTitle) private var headline: CGFloat = 64

    var body: some View {
        let down = Format.rateParts(model.snapshot.downloadBps)
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow("Débit descendant")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(down.value)
                    .font(.system(size: headline, weight: .bold, design: .monospaced))
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
        .accessibilityIdentifier("debit")
    }
}

private struct LiveChart: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let samples = model.samples
        Card {
            if samples.count < 2 {
                Text("La courbe apparaît après quelques secondes de mesure.")
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                Chart {
                    ForEach(samples) { sample in
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
                .chartYScale(domain: 0...Self.ceiling(of: samples))
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(Theme.line)
                        AxisValueLabel().foregroundStyle(Theme.tertiary)
                    }
                }
                .frame(height: 140)
                .accessibilityLabel("Débits descendant et montant de la dernière minute")
                .accessibilityValue(LiveChartText.summary(samples))
            }
        }
    }

    /// Le haut de l'échelle de la courbe, en Mb/s : un peu au-dessus du plus fort débit,
    /// et jamais moins d'un mégabit pour qu'un débit nul reste posé en bas.
    static func ceiling(of samples: [ThroughputSample]) -> Double {
        let peak = samples.reduce(0.0) { max($0, $1.downloadBps, $1.uploadBps) }
        return max(1, peak / 1_000_000 * 1.15)
    }
}

/// Ce que VoiceOver dit de la courbe en direct : le dernier relevé et le plus fort de
/// la minute, dans chaque sens.
enum LiveChartText {
    static func summary(_ samples: [ThroughputSample]) -> String {
        guard let last = samples.last else { return "Pas encore de mesure." }
        let peakDown = samples.map(\.downloadBps).max() ?? 0
        let peakUp = samples.map(\.uploadBps).max() ?? 0
        return "Maintenant : \(Format.rate(last.downloadBps)) descendant, \(Format.rate(last.uploadBps)) montant. "
            + "Sur la minute : jusqu’à \(Format.rate(peakDown)) descendant et \(Format.rate(peakUp)) montant."
    }
}

/// La disposition des mesures du tableau de bord, séparée de la vue pour être testée.
enum MeasureTilesLayout {
    static func columnCount(for size: DynamicTypeSize) -> Int {
        size.isAccessibilitySize ? 1 : 2
    }
}

private struct MeasureTiles: View {
    @Environment(AppModel.self) private var model

    @Environment(\.dynamicTypeSize) private var typeSize

    /// Deux colonnes, ou une seule aux tailles de texte d'accessibilité : les mesures
    /// restent lisibles en entier.
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: MeasureTilesLayout.columnCount(for: typeSize))
    }

    var body: some View {
        let snapshot = model.snapshot
        LazyVGrid(columns: columns, spacing: 12) {
            Tile("Latence", Format.milliseconds(snapshot.latencyMs))
            Tile("Gigue", Format.milliseconds(snapshot.jitterMs))
            Tile("Sondes sans réponse", Format.percent(snapshot.packetLossPercent))
            Tile(
                "Aujourd’hui",
                Format.bytes(snapshot.receivedBytesToday + snapshot.sentBytesToday),
                note: "Reçu et envoyé"
            )
        }
    }
}

/// Ce qui a été échangé pendant que l'app ne mesurait pas, lu sur les compteurs du
/// système à la reprise. Rien ne s'affiche pour une absence de moins d'une minute.
private struct AbsenceCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let absence = model.absence, absence.duration >= Launch.absenceMinimum {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow("Pendant que l’app était fermée")
                    Text(AbsenceText.headline(absence))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(Theme.text)
                    Text(AbsenceText.detail(absence))
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("hors-app")
        }
    }
}

/// Les phrases du rattrapage, séparées de l'écran pour être testées.
enum AbsenceText {
    /// « Au moins 1,80 Go en 2 h 05 ».
    static func headline(_ absence: AbsenceUsage) -> String {
        "Au moins \(Format.bytes(absence.totalBytes)) en \(Format.span(absence.duration))"
    }

    /// Le détail par réseau, et d'où vient le nombre.
    static func detail(_ absence: AbsenceUsage) -> String {
        let parts = absence.volumes
            .sorted { $0.totalBytes > $1.totalBytes }
            .map { "\($0.kind.title) : \(Format.bytes($0.totalBytes))" }
        let source = "D’après les compteurs du système, qui repartent de zéro tous les 4 Go."
        return parts.isEmpty ? source : parts.joined(separator: " · ") + ". " + source
    }
}

private struct PlanCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationLink {
            PlanView()
        } label: {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Eyebrow("Forfait mobile")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.tertiary)
                    }
                    if let status = model.plan {
                        PlanGauge(status: status)
                        Text(PlanText.summary(status))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(Theme.secondary)
                    } else {
                        Text("Suivre mon forfait")
                            .font(.headline)
                            .foregroundStyle(Theme.text)
                        Text("Indiquez son volume : FLUXA compte ce que l’iPhone consomme sur le réseau mobile, partage compris.")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("forfait")
    }
}

/// L'état du partage de connexion, déduit des interfaces du système.
private struct SharingCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Eyebrow("Partage de connexion")
                    Spacer()
                    if model.sharingDetected {
                        StatusPill(.supported, "Détecté")
                    } else {
                        StatusPill(.guide, "Non détecté")
                    }
                }
                if let sharing = model.sharing {
                    Text(SharingText.rates(sharing))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.text)
                    Text(SharingText.session(sharing.session))
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                } else {
                    Text("Activez le partage dans Réglages : FLUXA mesurera la connexion pendant que vous partagez.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                }
                if model.relayIsRunning {
                    Label(
                        RelayText.dashboardSummary(clients: model.relayStatus?.clients ?? [], rates: model.relayRates),
                        systemImage: "arrow.left.arrow.right.circle"
                    )
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.down)
                    .accessibilityIdentifier("resume-relais")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("partage")
    }
}

/// Les phrases du partage de connexion, séparées des écrans pour être testées.
enum SharingText {
    /// « ↓ 3,2 Mb/s vers les appareils · ↑ 0,4 Mb/s reçus ».
    static func rates(_ status: SharingStatus) -> String {
        "↓ \(Format.rate(status.toDevicesBps)) vers les appareils · ↑ \(Format.rate(status.fromDevicesBps)) reçus"
    }

    /// « Session de 12 min · 340,0 Mo », avec « au moins » si une partie a été rattrapée.
    static func session(_ session: SharingSession) -> String {
        "Session de \(Format.span(session.duration)) · \(volume(session))"
    }

    static func volume(_ session: SharingSession) -> String {
        let bytes = Format.bytes(session.totalBytes)
        return session.isLowerBound ? "au moins \(bytes)" : bytes
    }
}

private struct ProfileCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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
