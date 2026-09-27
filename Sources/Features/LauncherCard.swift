import SwiftUI

/// The ▶ cell at the end of the stack: the way into the Nx launcher.
struct LauncherCell: View {
    let workspaceCount: Int

    var body: some View {
        VStack(spacing: NotchLayout.ringLabelGap) {
            ZStack {
                Circle()
                    .strokeBorder(Palette.ringTrack, lineWidth: Design.px(6))
                Image(systemName: "play.fill")
                    .font(.system(size: NotchLayout.ringDiameter * 0.32, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    // Optical centring: a triangle's mass sits left of its box.
                    .offset(x: NotchLayout.ringDiameter * 0.04)
            }
            .frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)

            Text("NX")
                .font(Typography.percent)
                .foregroundStyle(workspaceCount > 0 ? Palette.textPrimary : Palette.textSecondary)
                .frame(height: NotchLayout.percentLineHeight)
        }
        .frame(height: NotchLayout.cellExtent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("Nx launcher"))
    }
}

/// The Nx workspaces your terminals are in, each project with its targets as
/// buttons. A button runs the target in a new Wave block beside the terminal
/// you already have open in that workspace.
struct LauncherCard: View {
    let entries: [NxLauncher.Entry]
    let direction: NotchEdge.TooltipDirection
    var tailOffset: CGFloat = 0
    let onLaunch: (NxLauncher.Entry, String, String) -> Void

    @Environment(\.codenotchReduceTransparency) private var reduceTransparency
    @Environment(\.notchSurfaceStyle) private var surfaceStyle
    @Environment(\.colorScheme) private var colorScheme

    /// Fixed, and the list scrolls inside it: a workspace can have dozens of
    /// projects, and the card has to fit beside the notch whatever it holds.
    static let cardHeight: CGFloat = Design.px(760)

    private var glassy: Bool { surfaceStyle.isGlass && !reduceTransparency }
    private var secondaryInk: Color {
        TooltipGlassContrast.secondaryInk(surfaceStyle: surfaceStyle, colorScheme: colorScheme,
                                          reduceTransparency: reduceTransparency)
    }
    /// Clear on glass, for the reason `UsageResetCard` gives.
    private var surfaceFill: Color { glassy ? .clear : Palette.card }

    private var clampedTailOffset: CGFloat {
        let size = TooltipTail.size(for: direction)
        switch direction {
        case .leading, .trailing:
            let maxOffset = max(0, (Self.cardHeight / 2) - NotchLayout.cardCorner - (size.height / 2))
            return min(max(tailOffset, -maxOffset), maxOffset)
        case .up, .down:
            let maxOffset = max(0, (NotchLayout.cardWidth / 2) - NotchLayout.cardCorner - (size.width / 2))
            return min(max(tailOffset, -maxOffset), maxOffset)
        }
    }

    var body: some View {
        stack
            .background {
                if glassy {
                    if #available(macOS 26.0, *) {
                        Color.clear
                            .glassEffect(surfaceStyle.glass, in: TooltipSilhouette(direction: direction, tailOffset: clampedTailOffset))
                            .background {
                                if let dim = TooltipGlassContrast.dim(surfaceStyle: surfaceStyle,
                                                                      colorScheme: colorScheme,
                                                                      reduceTransparency: reduceTransparency) {
                                    TooltipSilhouette(direction: direction, tailOffset: clampedTailOffset).fill(dim)
                                }
                            }
                    }
                }
            }
    }

    private var card: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
                .fill(surfaceFill)
                .frame(width: NotchLayout.cardWidth, height: Self.cardHeight)

            Group {
                if entries.isEmpty {
                    VStack(alignment: .leading, spacing: Design.px(12)) {
                        Text(L10n.t("Nx"))
                            .font(Typography.cardTitle)
                            .foregroundStyle(Palette.textPrimary)
                        Text(L10n.t("Open a Wave terminal in an Nx workspace and its projects show up here."))
                            .font(Typography.cardBody)
                            .foregroundStyle(secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(NotchLayout.cardPadding)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: Design.px(28)) {
                            ForEach(entries) { entry in
                                section(entry)
                            }
                        }
                        .padding(NotchLayout.cardPadding)
                    }
                }
            }
            .frame(width: NotchLayout.cardWidth, height: Self.cardHeight, alignment: .topLeading)
        }
        .frame(width: NotchLayout.cardWidth, height: Self.cardHeight, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular))
        .overlay {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
                    .strokeBorder(Palette.ringTrack, lineWidth: 1)
            }
        }
    }

    private func section(_ entry: NxLauncher.Entry) -> some View {
        VStack(alignment: .leading, spacing: Design.px(16)) {
            HStack(alignment: .firstTextBaseline, spacing: Design.px(12)) {
                Text(entry.workspace.name)
                    .font(Typography.cardTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                if entry.isOnScreen {
                    Text(L10n.t("on screen"))
                        .font(Typography.cardBody)
                        .foregroundStyle(Palette.ample)
                }
            }
            ForEach(entry.workspace.projects) { project in
                VStack(alignment: .leading, spacing: Design.px(8)) {
                    Text(project.name)
                        .font(Typography.cardBody.weight(project.isApp ? .semibold : .regular))
                        .foregroundStyle(project.isApp ? Palette.textPrimary : secondaryInk)
                        .lineLimit(1)
                    FlowLayout(spacing: Design.px(8)) {
                        ForEach(project.targets, id: \.self) { target in
                            Button { onLaunch(entry, project.name, target) } label: {
                                Text(target)
                                    .font(Typography.cardBody)
                                    .foregroundStyle(Palette.textPrimary)
                                    .padding(.horizontal, Design.px(16))
                                    .padding(.vertical, Design.px(6))
                                    .background(Capsule().fill(Palette.ringTrack))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help(entry.workspace.command(project: project.name, target: target))
                        }
                    }
                }
            }
        }
    }

    private var tail: some View {
        let size = TooltipTail.size(for: direction)
        return TooltipTail(direction: direction)
            .fill(surfaceFill)
            .frame(width: size.width, height: size.height)
            .offset(x: direction == .up || direction == .down ? clampedTailOffset : 0,
                    y: direction == .leading || direction == .trailing ? clampedTailOffset : 0)
    }

    @ViewBuilder private var stack: some View {
        switch direction {
        case .leading:
            HStack(spacing: 0) { card; tail }
        case .trailing:
            HStack(spacing: 0) { tail; card }
        case .down:
            VStack(spacing: 0) { tail; card }
        case .up:
            VStack(spacing: 0) { card; tail }
        }
    }
}

/// Target buttons laid out like words: as many to a line as fit, then the next.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let added = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if added > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
