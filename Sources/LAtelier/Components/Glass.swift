import LAtelierCore
import SwiftUI

/// Mise en page commune : fond teinté, défilement, en-tête, largeur de lecture.
struct PageScaffold<Actions: View, Content: View>: View {
    let page: Page
    var subtitle: String?
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(page: page, subtitle: subtitle) { actions }
                content
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background { Backdrop(tint: page.tint) }
    }
}

extension PageScaffold where Actions == EmptyView {
    init(page: Page, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(page: page, subtitle: subtitle, actions: { EmptyView() }, content: content)
    }
}

struct PageHeader<Actions: View>: View {
    let page: Page
    var subtitle: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: page.symbol)
                .font(.title2)
                .foregroundStyle(page.tint)
                .frame(width: 44, height: 44)
                .glassEffect(.regular.tint(page.tint.opacity(0.15)), in: .rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                if let group = page.group {
                    Text(group.title.uppercased())
                        .font(.caption2.weight(.semibold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                }
                Text(page.headerTitle).font(.largeTitle.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) { actions }
            }
        }
    }
}

/// Fond doux qui donne au verre quelque chose à réfracter.
struct Backdrop: View {
    var tint: Color

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [tint.opacity(0.16), .clear], center: .topTrailing, startRadius: 40, endRadius: 720)
            RadialGradient(colors: [Color.accentColor.opacity(0.08), .clear], center: .bottomLeading, startRadius: 40, endRadius: 640)
        }
        .ignoresSafeArea()
    }
}

/// Carte en verre.
struct GlassCard<Content: View>: View {
    var title: String?
    var symbol: String?
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Label {
                    Text(title).font(.headline)
                } icon: {
                    if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
                }
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

/// Badge de risque, le même partout.
struct RiskBadge: View {
    let risk: Risk

    var body: some View {
        Label(risk.label, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: .capsule)
    }

    var color: Color {
        switch risk {
        case .safe: .green
        case .caution: .orange
        case .danger: .red
        case .protected: .gray
        }
    }

    private var symbol: String {
        switch risk {
        case .safe: "checkmark.shield"
        case .caution: "exclamationmark.triangle"
        case .danger: "xmark.octagon"
        case .protected: "lock"
        }
    }
}

/// État vide : icône, phrase, action éventuelle.
struct EmptyState: View {
    let symbol: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(Int(seconds * 1000)) ms" : String(format: "%.1f s", seconds)
    }
}
