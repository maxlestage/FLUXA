import FluxaCore
import SwiftUI

/// Le centre de diagnostic : ce que l'iPhone permet, l'état du moteur et son journal.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // L'écran se relit quand l'historique ou les limites changent.
        let _ = model.historyRevision
        let diagnostics = model.diagnostics

        List {
            Section {
                ForEach(model.capabilities) { status in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(status.capability.title)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 12)
                            StatusPill(status.support.pill, status.support.title)
                        }
                        Text(status.note)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Capacités sur cet iPhone")
            } footer: {
                Text("Une limite de débit n’est annoncée comme effective que si le système confirme son application.")
            }

            Section("Moteur") {
                ValueRow("Version", diagnostics.engineVersion)
                ValueRow("Mesure", diagnostics.isMonitoring ? "Active" : "Arrêtée")
                ValueRow("Minutes enregistrées", "\(diagnostics.minuteAggregates)")
                ValueRow("Heures enregistrées", "\(diagnostics.hourAggregates)")
                ValueRow("Jours enregistrés", "\(diagnostics.dayAggregates)")
                ValueRow("Demandes de limite", "\(diagnostics.policyRecords)")
                if let location = diagnostics.storeLocation {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Emplacement des données")
                        Text(location)
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Capacités détectées") {
                Text(model.capabilitiesJSON)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
            }

            Section("Journal") {
                if diagnostics.events.isEmpty {
                    Text("Aucun événement.")
                        .foregroundStyle(Theme.secondary)
                }
                ForEach(diagnostics.events) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(event.level.title)
                                .font(.caption.monospaced().weight(.semibold))
                                .foregroundStyle(color(for: event.level))
                            Spacer()
                            Text(Format.dateTime(event.date))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.tertiary)
                        }
                        Text(event.message)
                            .font(.footnote)
                    }
                }
            }
        }
        .fluxaBackground()
        .navigationTitle("Diagnostic")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func color(for level: EngineEvent.Level) -> Color {
        switch level {
        case .info: Theme.secondary
        case .warning: Theme.up
        case .error: Theme.reserved
        }
    }
}
