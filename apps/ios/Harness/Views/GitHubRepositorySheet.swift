// Native GitHub repository Issues & PRs analytics browser — brings NanoHarness's
// warm-charcoal editorial analytics dashboard (apps/nano/src/view_github_overview.zig
// + view_github_repository.zig) to iOS using Theme tokens and DESIGN.md touch rules.

import SwiftUI

struct GitHubRepoLaunch: Identifiable, Equatable {
    let id = UUID()
    let initialKind: GitHubRepositoryKind
    let initialState: GitHubRepositoryState
    let initialNumber: UInt64?

    init(
        initialKind: GitHubRepositoryKind = .issues,
        initialState: GitHubRepositoryState = .all,
        initialNumber: UInt64? = nil
    ) {
        self.initialKind = initialKind
        self.initialState = initialState
        self.initialNumber = initialNumber
    }
}

struct GitHubRepositorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let chat: Chat
    let launch: GitHubRepoLaunch

    @State private var kind: GitHubRepositoryKind
    @State private var stateFilter: GitHubRepositoryState
    @State private var page: Int = 1
    @State private var response: BrowseCheckoutGitHubResponse?
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var clientFilter = GitHubClientFilter()
    @State private var pushedNumber: UInt64?

    init(chat: Chat, launch: GitHubRepoLaunch) {
        self.chat = chat
        self.launch = launch
        _kind = State(initialValue: launch.initialKind.isPull ? .pulls : .issues)
        _stateFilter = State(initialValue: launch.initialState)
        _pushedNumber = State(initialValue: launch.initialNumber)
    }

    private var repoName: String {
        response?.repository.fullName ?? "GitHub"
    }

    private var items: [GitHubRepositoryItem] {
        response?.items ?? []
    }

    private var stats: GitHubOverviewStats {
        GitHubOverviewStats.compute(items: items)
    }

    private var filteredItems: [GitHubRepositoryItem] {
        items.filter { clientFilter.matches($0) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controlsHeader
                Rectangle().fill(Theme.border).frame(height: 1)

                Group {
                    if loading && response == nil {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Loading \(kind == .pulls ? "pull requests" : "issues")…")
                                .font(Theme.sans(13))
                                .foregroundStyle(Theme.textMuted)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let errorMessage, response == nil {
                        ContentUnavailableView {
                            Label("Couldn't load repository", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(errorMessage)
                        } actions: {
                            Button("Try again") { Task { await loadPage() } }
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                if let errorMessage {
                                    Text(errorMessage)
                                        .font(Theme.sans(12.5))
                                        .foregroundStyle(Theme.warning)
                                        .padding(12)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Theme.warning.opacity(0.08),
                                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }

                                if !items.isEmpty {
                                    GitHubOverviewSection(
                                        stats: stats,
                                        isPull: kind.isPull,
                                        page: response?.page ?? page,
                                        hasNextPage: response?.hasNextPage ?? false,
                                        totalCount: items.count,
                                        shownCount: filteredItems.count,
                                        compactWidth: horizontalSizeClass == .compact,
                                        filter: $clientFilter
                                    )
                                }

                                listSection
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                        .refreshable { await loadPage() }
                    }
                }

                if let response, response.page > 1 || response.hasNextPage {
                    Rectangle().fill(Theme.border).frame(height: 1)
                    paginationFooter(response)
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(repoName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("github-sheet-done")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let urlString = response?.repository.url, let url = URL(string: urlString) {
                        Button {
                            openURL(url)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .accessibilityLabel("Open repository on GitHub")
                    }
                    Button {
                        Task { await loadPage() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(loading)
                    .accessibilityLabel("Refresh")
                    .accessibilityIdentifier("github-refresh")
                }
            }
            .navigationDestination(item: $pushedNumber) { number in
                GitHubItemDetailView(
                    chat: chat,
                    kind: kind.detailKind,
                    number: number,
                    expectedRepository: response?.repository.key
                )
            }
        }
        .task(id: "\(kind.rawValue)-\(stateFilter.rawValue)-\(page)") {
            await loadPage()
        }
        .harnessAppearance()
        .tint(Theme.text)
    }

    private var controlsHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                kindPicker
                Spacer(minLength: 4)
                if let repo = response?.repository {
                    Label(repo.host, systemImage: "checkmark.shield")
                        .font(Theme.sans(11.5, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                statePicker
                Spacer(minLength: 4)
                if loading && response != nil {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surface.opacity(0.6))
    }

    private var kindPicker: some View {
        HStack(spacing: 3) {
            pillSegment(
                title: "Pull requests",
                selected: kind == .pulls,
                identifier: "github-kind-pulls"
            ) {
                selectKind(.pulls)
            }
            pillSegment(
                title: "Issues",
                selected: kind == .issues,
                identifier: "github-kind-issues"
            ) {
                selectKind(.issues)
            }
        }
        .padding(3)
        .background(ink(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private var statePicker: some View {
        HStack(spacing: 3) {
            ForEach(GitHubRepositoryState.allCases) { st in
                pillSegment(
                    title: st.label,
                    selected: stateFilter == st,
                    identifier: "github-state-\(st.rawValue)"
                ) {
                    guard stateFilter != st else { return }
                    stateFilter = st
                    page = 1
                    clientFilter.clear()
                }
            }
        }
        .padding(3)
        .background(ink(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private func pillSegment(
        title: String,
        selected: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Text(title)
                .font(Theme.sans(12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Theme.text : Theme.textMuted)
                .padding(.horizontal, 10)
                .frame(minHeight: 28)
                .background(
                    selected ? AnyShapeStyle(Theme.surfaceRaised) : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var listSection: some View {
        let shown = filteredItems
        if shown.isEmpty {
            VStack(spacing: 10) {
                Text(items.isEmpty
                     ? "No \(kind == .pulls ? "pull requests" : "issues") on this page."
                     : "No items match the selected chart filters.")
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.textMuted)
                if clientFilter.isActive {
                    Button("Reset chart filters") {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        clientFilter.clear()
                    }
                    .font(Theme.sans(13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.surfaceRaised, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
                    .accessibilityIdentifier("github-reset-filters")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .background(ink(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        } else {
            VStack(spacing: 8) {
                ForEach(shown) { item in
                    GitHubItemCard(item: item, isPull: kind.isPull) {
                        pushedNumber = item.number
                    }
                }
            }
        }
    }

    private func paginationFooter(_ res: BrowseCheckoutGitHubResponse) -> some View {
        HStack {
            Button {
                guard res.page > 1 else { return }
                page = res.page - 1
                clientFilter.clear()
            } label: {
                Label("Previous", systemImage: "chevron.left")
                    .font(Theme.sans(13, weight: .medium))
                    .frame(minHeight: Theme.hitTarget)
            }
            .disabled(res.page <= 1 || loading)

            Spacer()

            Text("Page \(res.page)")
                .font(Theme.mono(12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.textMuted)

            Spacer()

            Button {
                guard res.hasNextPage else { return }
                page = res.page + 1
                clientFilter.clear()
            } label: {
                HStack(spacing: 4) {
                    Text("Next")
                    Image(systemName: "chevron.right")
                }
                .font(Theme.sans(13, weight: .medium))
                .frame(minHeight: Theme.hitTarget)
            }
            .disabled(!res.hasNextPage || loading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(Theme.surface)
    }

    private func selectKind(_ next: GitHubRepositoryKind) {
        guard kind != next else { return }
        kind = next
        page = 1
        clientFilter.clear()
    }

    private func loadPage() async {
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            response = try await model.browseCheckoutGitHub(
                chat: chat,
                kind: kind,
                state: stateFilter,
                page: page,
                expectedRepository: response?.repository.key
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Analytics Dashboard Cards

private struct GitHubOverviewSection: View {
    let stats: GitHubOverviewStats
    let isPull: Bool
    let page: Int
    let hasNextPage: Bool
    let totalCount: Int
    let shownCount: Int
    let compactWidth: Bool
    @Binding var filter: GitHubClientFilter

    @Environment(\.colorScheme) private var colorScheme

    private var cardFill: Color {
        ink(colorScheme == .dark ? 0.032 : 0.022)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if stats.total < 2 {
                compactSummaryStrip
            } else {
                kpiGrid
                if compactWidth {
                    stateSplitCard
                    if !stats.groups.isEmpty { groupsCard }
                    if !stats.days.isEmpty { daysCard }
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        stateSplitCard
                        if !stats.groups.isEmpty { groupsCard }
                        if !stats.days.isEmpty { daysCard }
                    }
                }
            }

            if filter.isActive {
                activeFilterBanner
            }
        }
    }

    private var compactSummaryStrip: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stats.openTotal > 0 && stats.resolved == 0 ? Theme.warning : Theme.statusCompleted)
                .frame(width: 7, height: 7)
            Text(compactSummaryText)
                .font(Theme.mono(12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private var compactSummaryText: String {
        let plus = hasNextPage ? "+" : ""
        let resolvedWord = stats.merged > 0 ? "merged" : "closed"
        let base = "On page: \(stats.total)\(plus) · \(stats.openTotal) open · \(stats.resolved) \(resolvedWord)"
        return stats.latestNumber > 0 ? "\(base) · #\(stats.latestNumber)" : base
    }

    private var kpiGrid: some View {
        let cols = Array(
            repeating: GridItem(.flexible(), spacing: 8),
            count: compactWidth ? 2 : 4
        )
        let openSub = stats.draft > 0
            ? "\(stats.draft) draft · \(stats.openPercent)%"
            : "\(stats.openPercent)% of page"
        let resolvedSub = isPull && stats.merged > 0
            ? "\(stats.merged) merged · \(stats.closed) closed"
            : "\(stats.resolvedPercent)% resolved"
        let contribSub = stats.topAuthor.isEmpty
            ? "no author"
            : "top: \(stats.topAuthor) (\(stats.topAuthorCount))"

        return LazyVGrid(columns: cols, spacing: 8) {
            kpiCard(
                label: "On This Page",
                value: "\(stats.total)\(hasNextPage ? "+" : "")",
                sub: "Page \(page) · latest #\(stats.latestNumber)",
                tone: Theme.text
            )
            kpiCard(
                label: "Open",
                value: "\(stats.openTotal)",
                sub: openSub,
                tone: Theme.warning
            )
            kpiCard(
                label: isPull ? "Merged / Closed" : "Closed",
                value: "\(stats.resolved)",
                sub: resolvedSub,
                tone: Theme.statusCompleted
            )
            kpiCard(
                label: "Contributors",
                value: "\(stats.contributorCount)",
                sub: contribSub,
                tone: Theme.accent
            )
        }
    }

    private func kpiCard(label: String, value: String, sub: String, tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(Theme.sans(11.5, weight: .medium))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
            Text(value)
                .font(Theme.sans(22, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(tone)
                .lineLimit(1)
            Text(sub)
                .font(Theme.mono(10.5))
                .monospacedDigit()
                .foregroundStyle(Theme.textFaint)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private var stateSplitCard: some View {
        let entries: [(chip: GitHubStateChip, label: String, count: Int, color: Color)] = [
            (.open, "Open", stats.open, Theme.warning),
            (.merged, "Merged", stats.merged, Theme.accent),
            (.closed, "Closed", stats.closed, Theme.statusCompleted),
            (.draft, "Draft", stats.draft, Theme.textMuted),
        ]
        let segments: [(count: Int, color: Color)] = [
            (stats.closed, Theme.statusCompleted),
            (stats.merged, Theme.accent),
            (stats.open, Theme.warning),
            (stats.draft, Theme.textMuted),
        ]

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("State Split")
                    .font(Theme.sans(13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text("Tap to filter")
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.textFaint)
            }

            HStack(spacing: 14) {
                ZStack {
                    Canvas { ctx, size in
                        let side = min(size.width, size.height)
                        let strokeW: CGFloat = 8.5
                        let radius = (side - strokeW) / 2
                        let center = CGPoint(x: size.width / 2, y: size.height / 2)

                        var track = Path()
                        track.addArc(center: center, radius: radius,
                                     startAngle: .degrees(0), endAngle: .degrees(360),
                                     clockwise: false)
                        ctx.stroke(track, with: .color(ink(colorScheme == .dark ? 0.08 : 0.06)),
                                   style: StrokeStyle(lineWidth: strokeW))

                        guard stats.total > 0 else { return }
                        var startDeg = -90.0
                        for seg in segments where seg.count > 0 {
                            let spanDeg = (Double(seg.count) / Double(stats.total)) * 360.0
                            var arc = Path()
                            arc.addArc(center: center, radius: radius,
                                       startAngle: .degrees(startDeg),
                                       endAngle: .degrees(startDeg + spanDeg),
                                       clockwise: false)
                            ctx.stroke(arc, with: .color(seg.color),
                                       style: StrokeStyle(lineWidth: strokeW, lineCap: .butt))
                            startDeg += spanDeg
                        }
                    }
                    .frame(width: 86, height: 86)

                    VStack(spacing: 1) {
                        Text("\(stats.resolvedPercent)%")
                            .font(Theme.mono(15, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.text)
                        Text("resolved")
                            .font(Theme.sans(9.5))
                            .foregroundStyle(Theme.textFaint)
                    }
                }

                VStack(spacing: 4) {
                    ForEach(entries.filter { $0.count > 0 }, id: \.chip.rawValue) { entry in
                        let active = filter.stateChip == entry.chip
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            filter.toggleState(entry.chip)
                        } label: {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(entry.color)
                                    .frame(width: 7, height: 7)
                                Text(entry.label)
                                    .font(Theme.sans(12, weight: active ? .semibold : .regular))
                                    .foregroundStyle(active ? Theme.text : Theme.textMuted)
                                Spacer(minLength: 4)
                                Text("\(entry.count)")
                                    .font(Theme.mono(12, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.text)
                            }
                            .padding(.horizontal, 8)
                            .frame(minHeight: 30)
                            .background(
                                active ? entry.color.opacity(0.14) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(active ? entry.color.opacity(0.45) : Color.clear, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Filter state: \(entry.label)")
                        .accessibilityIdentifier("github-filter-state-\(entry.chip.rawValue)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private var groupsCard: some View {
        let maxTotal = max(1, stats.groups.map(\.total).max() ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(stats.isLabelGrouping ? "By Label" : "By Contributor")
                    .font(Theme.sans(13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text("Tap to filter")
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.textFaint)
            }

            VStack(spacing: 4) {
                ForEach(stats.groups) { g in
                    let active = stats.isLabelGrouping
                        ? filter.label == g.name
                        : filter.author == g.name
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        if stats.isLabelGrouping {
                            filter.toggleLabel(g.name)
                        } else {
                            filter.toggleAuthor(g.name)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(g.name)
                                .font(Theme.sans(12, weight: active ? .semibold : .medium))
                                .foregroundStyle(active ? Theme.accent : Theme.text)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(width: 84, alignment: .leading)

                            Canvas { ctx, size in
                                let trackRect = CGRect(origin: .zero, size: size)
                                ctx.fill(
                                    Path(roundedRect: trackRect, cornerRadius: 4),
                                    with: .color(ink(colorScheme == .dark ? 0.06 : 0.05))
                                )
                                let denom = CGFloat(maxTotal)
                                let resW = g.resolved > 0 ? max(4, floor(size.width * CGFloat(g.resolved) / denom)) : 0
                                let openW = g.open > 0 ? max(4, floor(size.width * CGFloat(g.open) / denom)) : 0
                                if resW > 0 {
                                    ctx.fill(
                                        Path(roundedRect: CGRect(x: 0, y: 0, width: min(size.width, resW), height: size.height),
                                             cornerRadius: 3),
                                        with: .color(Theme.statusCompleted)
                                    )
                                }
                                if openW > 0 {
                                    let x = resW
                                    let avail = max(0, size.width - x)
                                    ctx.fill(
                                        Path(roundedRect: CGRect(x: x, y: 0, width: min(avail, openW), height: size.height),
                                             cornerRadius: 3),
                                        with: .color(Theme.warning)
                                    )
                                }
                            }
                            .frame(height: 10)

                            Text("\(g.resolved)/\(g.total)")
                                .font(Theme.mono(11))
                                .monospacedDigit()
                                .foregroundStyle(Theme.textMuted)
                                .frame(width: 38, alignment: .trailing)
                        }
                        .padding(.horizontal, 6)
                        .frame(minHeight: 32)
                        .background(
                            active ? Theme.accent.opacity(0.11) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(active ? Theme.accent.opacity(0.42) : Color.clear, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Filter \(stats.isLabelGrouping ? "label" : "author"): \(g.name)")
                    .accessibilityIdentifier("github-filter-group-\(g.name)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private var daysCard: some View {
        let maxDay = max(1, stats.days.map { max($0.open, $0.resolved) }.max() ?? 1)
        let maxBarH: CGFloat = 64

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent Activity")
                    .font(Theme.sans(13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                HStack(spacing: 8) {
                    miniLegendDot(Theme.warning, "Open")
                    miniLegendDot(Theme.statusCompleted, "Closed")
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                ForEach(stats.days) { d in
                    VStack(spacing: 5) {
                        HStack(alignment: .bottom, spacing: 3) {
                            if d.open > 0 {
                                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                    .fill(Theme.warning)
                                    .frame(width: 9, height: max(5, round(maxBarH * CGFloat(d.open) / CGFloat(maxDay))))
                            }
                            if d.resolved > 0 {
                                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                    .fill(Theme.statusCompleted)
                                    .frame(width: 9, height: max(5, round(maxBarH * CGFloat(d.resolved) / CGFloat(maxDay))))
                            }
                            if d.open == 0 && d.resolved == 0 {
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(ink(0.08))
                                    .frame(width: 9, height: 3)
                            }
                        }
                        .frame(height: maxBarH, alignment: .bottom)

                        Text(d.shortLabel)
                            .font(Theme.mono(10))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textFaint)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private func miniLegendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(Theme.sans(10.5))
                .foregroundStyle(Theme.textMuted)
        }
    }

    private var activeFilterBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(filter.summary(shown: shownCount, total: totalCount))
                .font(Theme.sans(12, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                filter.clear()
            } label: {
                Text("Clear filter")
                    .font(Theme.sans(11.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 9)
                    .frame(minHeight: 26)
                    .background(ink(0.06), in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("github-clear-filter")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.accent.opacity(colorScheme == .dark ? 0.11 : 0.08),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - Item Card

private struct GitHubItemCard: View {
    let item: GitHubRepositoryItem
    let isPull: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var tone: Color {
        gitHubTone(state: item.state, isDraft: item.isDraft)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    GitHubStatePill(number: item.number, state: item.state, isDraft: item.isDraft, isPull: isPull)

                    ForEach(Array(item.labels.prefix(3)), id: \.self) { label in
                        Text(label)
                            .font(Theme.sans(11, weight: .medium))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background(ink(0.05), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(Theme.border, lineWidth: 1)
                            )
                    }

                    Spacer(minLength: 4)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                }

                Text(item.title)
                    .font(Theme.sans(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                HStack(spacing: 5) {
                    Image(systemName: "person")
                        .font(.system(size: 10.5))
                    Text("\(item.author.isEmpty ? "unknown" : item.author) · updated \(GitHubOverviewStats.dayPrefix(item.updatedAt) ?? item.updatedAt)")
                        .font(Theme.sans(12))
                        .lineLimit(1)
                }
                .foregroundStyle(Theme.textMuted)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ink(colorScheme == .dark ? 0.032 : 0.022),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressWashButtonStyle(cornerRadius: 12, scale: 0.99))
        .accessibilityIdentifier("github-item-\(item.number)")
    }
}

private struct GitHubStatePill: View {
    let number: UInt64
    let state: String
    let isDraft: Bool
    let isPull: Bool

    private var tone: Color {
        gitHubTone(state: state, isDraft: isDraft)
    }

    var body: some View {
        HStack(spacing: 4) {
            if isPull {
                LineIconView(.pullRequest, size: 11, color: tone)
            } else {
                Image(systemName: state.lowercased() == "closed" ? "checkmark.circle" : "circle.inset.filled")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(tone)
            }
            Text("#\(number) · \(state)\(isDraft ? " · draft" : "")")
                .font(Theme.mono(11, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .tintedChip(tone, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private func gitHubTone(state: String, isDraft: Bool) -> Color {
    if isDraft { return Theme.textMuted }
    switch state.lowercased() {
    case "open": return Theme.warning
    case "closed": return Theme.statusCompleted
    default: return Theme.accent
    }
}

// MARK: - Detail View (Summary, Files, Activity)

private enum GitHubDetailTab: String, CaseIterable, Identifiable {
    case summary = "Summary"
    case files = "Files"
    case activity = "Activity"

    var id: String { rawValue }
}

private struct GitHubItemDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme

    let chat: Chat
    let kind: GitHubRepositoryKind
    let number: UInt64
    let expectedRepository: String?

    @State private var tab: GitHubDetailTab = .summary
    @State private var detailResponse: BrowseCheckoutGitHubResponse?
    @State private var filesResponse: BrowseCheckoutGitHubResponse?
    @State private var activityResponse: BrowseCheckoutGitHubResponse?
    @State private var loadingDetail = false
    @State private var loadingFiles = false
    @State private var loadingActivity = false
    @State private var errorMessage: String?
    @State private var expandedFile: String?

    private var availableTabs: [GitHubDetailTab] {
        kind == .pull ? [.summary, .files, .activity] : [.summary, .activity]
    }

    private var detail: GitHubRepositoryDetail? {
        detailResponse?.detail
    }

    var body: some View {
        VStack(spacing: 0) {
            if let detail {
                detailHeader(detail)
                Rectangle().fill(Theme.border).frame(height: 1)
                Picker("Detail", selection: $tab) {
                    ForEach(availableTabs) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if loadingDetail && detail == nil {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                    } else if let errorMessage, detail == nil {
                        ContentUnavailableView {
                            Label("Couldn't load #\(number)", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(errorMessage)
                        } actions: {
                            Button("Try again") { Task { await loadDetail() } }
                                .buttonStyle(.borderedProminent)
                        }
                    } else if let detail {
                        switch tab {
                        case .summary:
                            summaryTab(detail)
                        case .files:
                            filesTab
                        case .activity:
                            activityTab
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("#\(number)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let rawUrl = detail?.url, let url = URL(string: rawUrl) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        openURL(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .accessibilityLabel("Open on GitHub")
                }
            }
        }
        .task(id: number) {
            await loadDetail()
        }
        .task(id: tab) {
            if tab == .files && filesResponse == nil {
                await loadFiles()
            } else if tab == .activity && activityResponse == nil {
                await loadActivity()
            }
        }
    }

    private func detailHeader(_ d: GitHubRepositoryDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                GitHubStatePill(number: d.number, state: d.state, isDraft: d.isDraft, isPull: kind == .pull)
                ForEach(Array(d.labels.prefix(4)), id: \.self) { label in
                    Text(label)
                        .font(Theme.sans(11, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(ink(0.05), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                }
                Spacer(minLength: 0)
            }

            Text(d.title)
                .font(Theme.sans(17, weight: .semibold))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)

            HStack(spacing: 6) {
                Text(d.author.isEmpty ? "unknown" : d.author)
                Text("·")
                Text("created \(GitHubOverviewStats.dayPrefix(d.createdAt) ?? d.createdAt)")
                Text("·")
                Text("updated \(GitHubOverviewStats.dayPrefix(d.updatedAt) ?? d.updatedAt)")
            }
            .font(Theme.sans(12))
            .foregroundStyle(Theme.textMuted)
            .lineLimit(1)

            if let head = d.headRef, let base = d.baseRef {
                Text("\(head) → \(base)")
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(ink(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            }

            if let add = d.additions, let del = d.deletions {
                let filesCount = d.changedFiles ?? 0
                HStack(spacing: 8) {
                    Text("+\(add)")
                        .font(Theme.mono(12, weight: .semibold))
                        .foregroundStyle(Theme.statusCompleted)
                    Text("-\(del)")
                        .font(Theme.mono(12, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                    diffRatioBar(additions: add, deletions: del)
                    Text("· \(filesCount) \(filesCount == 1 ? "file" : "files")")
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.45))
    }

    private func diffRatioBar(additions: UInt64, deletions: UInt64) -> some View {
        let total = additions + deletions
        return Canvas { ctx, size in
            guard total > 0 else { return }
            let addFrac = CGFloat(additions) / CGFloat(total)
            let addW = additions > 0 ? max(4, floor(size.width * addFrac)) : 0
            let delW = deletions > 0 ? max(4, size.width - addW) : 0
            if additions > 0 {
                ctx.fill(Path(CGRect(x: 0, y: 0, width: min(size.width, addW), height: size.height)),
                         with: .color(Theme.statusCompleted))
            }
            if deletions > 0 {
                ctx.fill(Path(CGRect(x: addW, y: 0, width: min(max(0, size.width - addW), delW), height: size.height)),
                         with: .color(Theme.danger))
            }
        }
        .frame(width: 48, height: 6)
        .clipShape(Capsule())
    }

    private func summaryTab(_ d: GitHubRepositoryDetail) -> some View {
        let trimmed = d.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 10) {
            if trimmed.isEmpty {
                Text("No description provided.")
                    .font(Theme.sans(14))
                    .foregroundStyle(Theme.textMuted)
            } else {
                let blocks = MarkdownParser.parse(d.body)
                ForEach(Array(blocks.enumerated()), id: \.offset) { idx, item in
                    MarkdownBlockView(block: item.block, cacheKey: "gh-\(d.number)-\(idx)")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ink(colorScheme == .dark ? 0.032 : 0.022),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    @ViewBuilder
    private var filesTab: some View {
        if loadingFiles && filesResponse == nil {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 36)
        } else if let files = filesResponse?.files, !files.isEmpty {
            ForEach(files) { file in
                let expanded = expandedFile == file.filename
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        expandedFile = expanded ? nil : file.filename
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                                .foregroundStyle(Theme.textFaint)
                            Text(file.filename)
                                .font(Theme.mono(12.5))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text("+\(file.additions)")
                                .font(Theme.mono(12))
                                .foregroundStyle(Theme.statusCompleted)
                            Text("-\(file.deletions)")
                                .font(Theme.mono(12))
                                .foregroundStyle(Theme.danger)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if expanded {
                        Rectangle().fill(Theme.border).frame(height: 1)
                        if let patch = file.patch, !patch.isEmpty {
                            let hunks = UnifiedDiffParser.parse("diff --git a/\(file.filename) b/\(file.filename)\n@@ -1,1 +1,1 @@\n\(patch)").first?.hunks
                                ?? [DiffHunk(header: "", lines: patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { idx, line in
                                    let s = String(line)
                                    let k: DiffLine.Kind = s.hasPrefix("+") ? .added : (s.hasPrefix("-") ? .removed : .context)
                                    let body = (s.hasPrefix("+") || s.hasPrefix("-") || s.hasPrefix(" ")) ? String(s.dropFirst()) : s
                                    return DiffLine(id: idx, kind: k, text: body)
                                })]
                            ScrollView(.horizontal) {
                                VStack(alignment: .leading, spacing: 1) {
                                    ForEach(hunks) { hunk in
                                        ForEach(hunk.lines) { line in
                                            let tint: Color = line.kind == .added ? Theme.statusCompleted
                                                : line.kind == .removed ? Theme.danger : .clear
                                            HStack(spacing: 4) {
                                                Text(line.kind == .added ? "+" : (line.kind == .removed ? "-" : " "))
                                                    .foregroundStyle(tint == .clear ? Theme.textFaint : tint)
                                                HighlightedCodeLine(
                                                    text: line.text,
                                                    language: HighlightLanguage.forTag((file.filename as NSString).pathExtension) ?? .swift
                                                )
                                            }
                                            .font(Theme.mono(12))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 1)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(tint.opacity(0.10))
                                        }
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                        } else {
                            Text("No line patch available (binary or truncated).")
                                .font(Theme.sans(12))
                                .foregroundStyle(Theme.textFaint)
                                .padding(12)
                        }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            }
        } else {
            Text("No files on this page.")
                .font(Theme.sans(13))
                .foregroundStyle(Theme.textMuted)
        }
    }

    @ViewBuilder
    private var activityTab: some View {
        if loadingActivity && activityResponse == nil {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 36)
        } else if let events = activityResponse?.events, !events.isEmpty {
            ForEach(events) { ev in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(ev.author.isEmpty ? "unknown" : ev.author)
                            .font(Theme.sans(13, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text(ev.event)
                            .font(Theme.sans(12))
                            .foregroundStyle(Theme.textMuted)
                        if let sha = ev.commitSha, !sha.isEmpty {
                            Text(String(sha.prefix(7)))
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                        }
                        Spacer(minLength: 4)
                        Text(GitHubOverviewStats.dayPrefix(ev.createdAt) ?? ev.createdAt)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.textFaint)
                    }
                    if let body = ev.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(body)
                            .font(Theme.sans(13.5))
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ink(colorScheme == .dark ? 0.032 : 0.022),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            }
        } else {
            Text("No activity yet.")
                .font(Theme.sans(13))
                .foregroundStyle(Theme.textMuted)
        }
    }

    private func loadDetail() async {
        loadingDetail = true
        errorMessage = nil
        defer { loadingDetail = false }
        do {
            detailResponse = try await model.browseCheckoutGitHub(
                chat: chat, kind: kind, number: number, expectedRepository: expectedRepository
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadFiles() async {
        loadingFiles = true
        defer { loadingFiles = false }
        filesResponse = try? await model.browseCheckoutGitHub(
            chat: chat, kind: .files, number: number, expectedRepository: expectedRepository
        )
        if expandedFile == nil {
            expandedFile = filesResponse?.files.first?.filename
        }
    }

    private func loadActivity() async {
        loadingActivity = true
        defer { loadingActivity = false }
        activityResponse = try? await model.browseCheckoutGitHub(
            chat: chat, kind: .activity, number: number, expectedRepository: expectedRepository
        )
    }
}
