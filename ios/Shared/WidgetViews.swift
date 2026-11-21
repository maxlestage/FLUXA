import SwiftUI

/// Les formats de widget de FLUXA. Les vues sont de simples vues SwiftUI : l'extension
/// des widgets les affiche, et l'app les montre en aperçu dans ses réglages.
enum WidgetLayout: CaseIterable {
    case small, medium, circular, rectangular, inline
}

/// Les phrases des widgets, séparées des vues pour être testées.
enum WidgetText {
    /// « Relevé à 14:32 », ou « Relevé le 20 nov. » pour un autre jour.
    static func updated(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "Relevé à " + date.formatted(.dateTime.hour().minute().locale(Format.locale))
        }
        return "Relevé le " + Format.day(date)
    }

    static func planRemaining(_ plan: WidgetSnapshot.Plan) -> String {
        plan.usedBytes >= plan.allowanceBytes ? "Forfait dépassé" : "Reste \(Format.bytes(plan.remainingBytes))"
    }

    static func percent(_ fraction: Double) -> String {
        Format.percent(fraction * 100)
    }

    static let empty = "Ouvrez FLUXA pour afficher vos mesures."

    /// Le jour du volume affiché : « Aujourd’hui », ou « Le 20 nov. » pour un relevé d'un
    /// autre jour. Après minuit, le volume de la veille n'est pas présenté comme celui du jour.
    static func day(of date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now) ? "Aujourd’hui" : "Le \(Format.day(date))"
    }
}

struct FluxaWidgetView: View {
    let snapshot: WidgetSnapshot?
    let layout: WidgetLayout
    /// L'instant affiché : celui de l'entrée de la chronologie du widget.
    var now = Date()

    var body: some View {
        if let snapshot {
            switch layout {
            case .small: SmallWidget(snapshot: snapshot, now: now)
            case .medium: MediumWidget(snapshot: snapshot, now: now)
            case .circular: CircularWidget(snapshot: snapshot)
            case .rectangular: RectangularWidget(snapshot: snapshot, now: now)
            case .inline:
                Text("FLUXA · \(Format.bytes(snapshot.todayBytes)) · \(WidgetText.day(of: snapshot.updatedAt, now: now).lowercased())")
            }
        } else {
            switch layout {
            case .circular: Image(systemName: "waveform.path.ecg")
            case .inline: Text("FLUXA")
            default:
                VStack(alignment: .leading, spacing: 6) {
                    Brand(isOnline: nil)
                    Spacer(minLength: 0)
                    Text(WidgetText.empty)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }
}

private struct Brand: View {
    let isOnline: Bool?

    var body: some View {
        HStack {
            Text("FLUXA")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(Theme.down)
            Spacer()
            if let isOnline {
                Circle()
                    .fill(isOnline ? Theme.ok : Theme.reserved)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel(isOnline ? "Connecté" : "Hors ligne")
            }
        }
    }
}

private struct TodayBlock: View {
    let snapshot: WidgetSnapshot
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(WidgetText.day(of: snapshot.updatedAt, now: now))
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
            Text(Format.bytes(snapshot.todayBytes))
                .font(.title2.monospacedDigit().weight(.bold))
                .foregroundStyle(Theme.text)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text("↓ \(Format.rate(snapshot.downloadBps))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.down)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(WidgetText.updated(snapshot.updatedAt, now: now))
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

private struct SmallWidget: View {
    let snapshot: WidgetSnapshot
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Brand(isOnline: snapshot.isOnline)
            Spacer(minLength: 0)
            TodayBlock(snapshot: snapshot, now: now)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct MediumWidget: View {
    let snapshot: WidgetSnapshot
    let now: Date

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Brand(isOnline: nil)
                Spacer(minLength: 0)
                TodayBlock(snapshot: snapshot, now: now)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(snapshot.network)
                    .font(.caption2)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let plan = snapshot.plan {
                    Text("Forfait")
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)
                    ProgressView(value: min(max(plan.fractionUsed, 0), 1))
                        .tint(plan.fractionUsed >= 1 ? Theme.reserved : (plan.fractionUsed >= 0.8 ? Theme.up : Theme.ok))
                    Text(WidgetText.planRemaining(plan))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                if let relay = snapshot.relay {
                    Label(RelayActivityText.devices(relay.devices), systemImage: "arrow.left.arrow.right.circle")
                        .font(.caption)
                        .foregroundStyle(Theme.down)
                        .lineLimit(1)
                }
                if snapshot.plan == nil, snapshot.relay == nil {
                    Text("↑ \(Format.rate(snapshot.uploadBps))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.up)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

private struct CircularWidget: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        if let plan = snapshot.plan {
            Gauge(value: min(max(plan.fractionUsed, 0), 1)) {
                Image(systemName: "simcard")
            } currentValueLabel: {
                Text(WidgetText.percent(plan.fractionUsed))
                    .minimumScaleFactor(0.5)
            }
            .gaugeStyle(.accessoryCircular)
            .accessibilityLabel("Forfait utilisé : \(WidgetText.percent(plan.fractionUsed))")
        } else {
            VStack(spacing: 0) {
                Image(systemName: "arrow.down")
                    .font(.caption2)
                Text(Format.rateParts(snapshot.downloadBps).value)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .minimumScaleFactor(0.5)
                Text(Format.rateParts(snapshot.downloadBps).unit)
                    .font(.system(size: 9))
            }
        }
    }
}

private struct RectangularWidget: View {
    let snapshot: WidgetSnapshot
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("FLUXA · \(WidgetText.day(of: snapshot.updatedAt, now: now).lowercased())")
                .font(.caption2.weight(.semibold))
            Text(Format.bytes(snapshot.todayBytes))
                .font(.headline.monospacedDigit())
            if let plan = snapshot.plan {
                Text(WidgetText.planRemaining(plan))
                    .font(.caption2)
            } else {
                Text(WidgetText.updated(snapshot.updatedAt, now: now))
                    .font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - L'activité en direct du relais

/// L'activité sur l'écran verrouillé.
struct RelayActivityBanner: View {
    let startedAt: Date
    let state: RelayActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.left.arrow.right.circle.fill")
                .font(.title2)
                .foregroundStyle(Theme.down)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Relais de partage")
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Text(startedAt, style: .timer)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 90, alignment: .trailing)
                }
                Text("\(RelayActivityText.devices(state.devices)) · ↓ \(RelayActivityText.rate(state.toDevicesBps))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.text)
                Text("Plafond : \(state.cap)")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                HStack(spacing: 4) {
                    Text("Mis à jour")
                    Text(state.updatedAt, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
            }
        }
        .padding(16)
    }
}

/// Les morceaux de la Dynamic Island, partagés par l'extension et l'aperçu de l'app.
enum RelayIsland {
    struct CompactLeading: View {
        var body: some View {
            Image(systemName: "arrow.left.arrow.right.circle.fill")
                .foregroundStyle(Theme.down)
                .accessibilityLabel("Relais de partage")
        }
    }

    struct CompactTrailing: View {
        let state: RelayActivityAttributes.ContentState

        var body: some View {
            HStack(spacing: 2) {
                Text("\(state.devices)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.caption2)
            }
            .foregroundStyle(Theme.down)
            .accessibilityLabel(RelayActivityText.devices(state.devices))
        }
    }

    struct ExpandedLeading: View {
        let state: RelayActivityAttributes.ContentState

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Label("Relais", systemImage: "arrow.left.arrow.right.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.down)
                Text(RelayActivityText.devices(state.devices))
                    .font(.subheadline)
            }
        }
    }

    struct ExpandedTrailing: View {
        let startedAt: Date
        let state: RelayActivityAttributes.ContentState

        var body: some View {
            VStack(alignment: .trailing, spacing: 2) {
                Text("↓ \(RelayActivityText.rate(state.toDevicesBps))")
                    .font(.subheadline.monospacedDigit())
                Text(startedAt, style: .timer)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    struct ExpandedBottom: View {
        let state: RelayActivityAttributes.ContentState

        var body: some View {
            HStack {
                Text("Plafond : \(state.cap)")
                Spacer()
                Text("Mis à jour")
                Text(state.updatedAt, style: .relative)
            }
            .font(.caption2)
            .foregroundStyle(Theme.secondary)
        }
    }
}
