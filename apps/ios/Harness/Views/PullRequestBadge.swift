import SwiftUI

enum PullRequestBadgeSurface {
    case sessionRow
    case composer
}

extension ChangeRequestState {
    var badgeColor: Color {
        switch self {
        case .open: return Theme.warning
        case .merged: return Theme.accent
        case .closed: return Theme.statusCompleted
        }
    }
}

extension ChangeRequestSummary {
    var accessibilityLabel: String {
        "Pull request \(number), \(state.label), \(title)"
    }
}

/// Shared provider-neutral PR affordance. The full title stays available to
/// VoiceOver while narrow surfaces render only the stable numeric identity.
struct PullRequestBadge: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    let summary: ChangeRequestSummary
    var surface: PullRequestBadgeSurface = .sessionRow
    var onOpen: (() -> Void)? = nil

    private var composer: Bool { surface == .composer }

    var body: some View {
        Button {
            if let onOpen {
                onOpen()
            } else if let url = URL(string: summary.url) {
                openURL(url)
            }
        } label: {
            HStack(spacing: composer ? 6 : 0) {
                if composer {
                    LineIconView(.pullRequest, size: 14,
                                 color: TintedChipStyle.text(summary.state.badgeColor, dark: colorScheme == .dark))
                }
                Text("#\(summary.number)")
                    .font(Theme.mono(composer ? 12 : 10, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, composer ? 12 : 6)
            .frame(height: composer ? 40 : 20)
            // A soft tint of the state's hue under darker text in that hue (DESIGN.md "Status and tag chips").
            .tintedChip(summary.state.badgeColor, in: badgeShape)
            .contentShape(badgeShape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(summary.accessibilityLabel)
        .accessibilityHint(onOpen != nil ? "Opens GitHub dashboard" : "Opens in your browser")
    }

    private var badgeShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: composer ? 12 : 5)
    }
}

/// Read-only checkout context in an existing session's composer.
struct BranchContextChip: View {
    let branch: String

    var body: some View {
        HStack(spacing: 6) {
            LineIconView(.gitBranch, size: 14, color: Theme.textMuted)
            Text(branch)
                .font(Theme.sans(12, weight: .medium))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Branch \(branch)")
    }
}
