import SwiftUI

/// Les couleurs de FLUXA, les mêmes que celles du site.
enum Theme {
    static let background = Color(hex: 0x090B14)
    static let surface = Color(hex: 0x0F1220)
    static let raised = Color(hex: 0x171B2E)
    static let line = Color(hex: 0x272C47)
    static let text = Color(hex: 0xECEEF8)
    static let secondary = Color(hex: 0xAEB3CB)
    static let tertiary = Color(hex: 0x858CAB)

    /// Le sens descendant.
    static let down = Color(hex: 0x7CD4FD)
    /// Le sens montant.
    static let up = Color(hex: 0xFFB37A)

    static let ok = Color(hex: 0x6FDDA6)
    static let simulated = Color(hex: 0xC2A9FF)
    static let reserved = Color(hex: 0xF0868C)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Le statut réel d'une fonction : sa couleur et sa forme le disent autant que son texte.
struct StatusPill: View {
    enum Kind {
        case supported, simulated, guide, reserved

        var color: Color {
            switch self {
            case .supported: Theme.ok
            case .simulated: Theme.simulated
            case .guide: Theme.secondary
            case .reserved: Theme.reserved
            }
        }
    }

    let kind: Kind
    let label: String

    init(_ kind: Kind, _ label: String) {
        self.kind = kind
        self.label = label
    }

    var body: some View {
        HStack(spacing: 6) {
            marker
            Text(label)
                .font(.caption.monospaced().weight(.medium))
        }
        .foregroundStyle(kind.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(kind.color.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(kind.color.opacity(0.4), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var marker: some View {
        switch kind {
        case .supported:
            Circle().frame(width: 7, height: 7)
        case .simulated:
            Circle().strokeBorder(lineWidth: 1.5).frame(width: 8, height: 8)
        case .guide:
            RoundedRectangle(cornerRadius: 2).frame(width: 7, height: 7)
        case .reserved:
            Capsule().frame(width: 9, height: 2)
        }
    }
}

/// Un bloc de contenu sur une surface relevée.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1)
            )
    }
}

/// Une petite étiquette en capitales, au-dessus d'un bloc.
struct Eyebrow: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.monospaced().weight(.medium))
            .tracking(1.2)
            .foregroundStyle(Theme.tertiary)
    }
}

/// Une ligne « libellé, valeur ».
struct ValueRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        LabeledContent(label) {
            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(Theme.text)
        }
    }
}

extension View {
    /// Le fond de l'app sous une liste ou un formulaire.
    func fluxaBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.background)
    }
}
