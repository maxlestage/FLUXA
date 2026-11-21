import ActivityKit
import SwiftUI
import WidgetKit

/// Les widgets de FLUXA et l'activité en direct du relais.
@main
struct FluxaWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        RelayLiveActivity()
    }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

/// Le widget relit le dernier relevé de l'app. Il ne mesure rien : quand l'app enregistre
/// un nouveau relevé, elle demande au système de rafraîchir les widgets.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .example)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        // Dans la galerie, un exemple ; sur l'écran, le vrai relevé.
        let snapshot = context.isPreview ? (WidgetSnapshot.load() ?? .example) : WidgetSnapshot.load()
        completion(SnapshotEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: Date(), snapshot: WidgetSnapshot.load())
        // Relire de temps en temps : l'heure du relevé change de jour à minuit.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FluxaToday", provider: SnapshotProvider()) { entry in
            FamilyView(snapshot: entry.snapshot)
                .containerBackground(for: .widget) {
                    Theme.background
                }
        }
        .configurationDisplayName("FLUXA")
        .description("Le volume du jour, le débit et le forfait, au dernier relevé de l’app.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct FamilyView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot?

    var body: some View {
        FluxaWidgetView(snapshot: snapshot, layout: layout)
    }

    private var layout: WidgetLayout {
        switch family {
        case .systemMedium, .systemLarge, .systemExtraLarge: .medium
        case .accessoryCircular: .circular
        case .accessoryRectangular: .rectangular
        case .accessoryInline: .inline
        default: .small
        }
    }
}

struct RelayLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RelayActivityAttributes.self) { context in
            RelayActivityBanner(startedAt: context.attributes.startedAt, state: context.state)
                .activityBackgroundTint(Theme.background)
                .activitySystemActionForegroundColor(Theme.down)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RelayIsland.ExpandedLeading(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RelayIsland.ExpandedTrailing(startedAt: context.attributes.startedAt, state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RelayIsland.ExpandedBottom(state: context.state)
                }
            } compactLeading: {
                RelayIsland.CompactLeading()
            } compactTrailing: {
                RelayIsland.CompactTrailing(state: context.state)
            } minimal: {
                RelayIsland.CompactLeading()
            }
            .keylineTint(Theme.down)
        }
    }
}
