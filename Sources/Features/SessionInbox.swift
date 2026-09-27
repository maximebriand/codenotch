import SwiftUI

/// The bell at the end of the stack: how many sessions are waiting on you.
///
/// A cell like the rings beside it — same column, same label line — so the
/// notch keeps one rhythm. Hovering it opens `InboxCard`, the list of what to
/// do, which is what the rings' own cards are not: they answer "how much have
/// I used", and this answers "what is waiting for me".
struct InboxCell: View {
    let count: Int

    var body: some View {
        VStack(spacing: NotchLayout.ringLabelGap) {
            ZStack {
                Circle()
                    .strokeBorder(count > 0 ? Palette.watch : Palette.ringTrack,
                                  lineWidth: Design.px(6))
                Image(systemName: count > 0 ? "bell.fill" : "bell")
                    .font(.system(size: NotchLayout.ringDiameter * 0.36, weight: .semibold))
                    .foregroundStyle(count > 0 ? Palette.watch : Palette.textSecondary)
            }
            .frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)

            Text(count > 0 ? "\(count)" : "—")
                .font(Typography.percent)
                .foregroundStyle(count > 0 ? Palette.textPrimary : Palette.textSecondary)
                .frame(height: NotchLayout.percentLineHeight)
                .contentTransition(.numericText())
                .animation(NotchMotion.reading, value: count)
        }
        .frame(height: NotchLayout.cellExtent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count == 1 ? L10n.t("1 session waiting on you")
                                       : L10n.t("\(count) sessions waiting on you"))
    }
}

/// What is waiting on you, one row per session: what it is about, where, and
/// what it asked or said — with a way to go there, or to clear it.
struct InboxCard: View {
    let items: [SessionPrompt]
    let direction: NotchEdge.TooltipDirection
    var tailOffset: CGFloat = 0
    let onGo: (SessionPrompt) -> Void
    let onDismiss: (SessionPrompt) -> Void

    @Environment(\.codenotchReduceTransparency) private var reduceTransparency
    @Environment(\.notchSurfaceStyle) private var surfaceStyle
    @Environment(\.colorScheme) private var colorScheme

    /// More than this and the rest are counted, not listed: the card has to
    /// fit beside the notch, and the oldest waits are the least likely to be
    /// the one you are after.
    static let maxRows = 4
    static let headerHeight: CGFloat = Design.px(64)
    static let rowHeight: CGFloat = Design.px(168)
    static let moreHeight: CGFloat = Design.px(44)
    static let emptyHeight: CGFloat = Design.px(56)

    /// Exact, because the notch's hit region and the card's position are both
    /// computed from it before the card is ever drawn.
    static func height(itemCount: Int) -> CGFloat {
        let rows = min(itemCount, maxRows)
        let body = rows == 0 ? emptyHeight : CGFloat(rows) * rowHeight
        let more = itemCount > maxRows ? moreHeight : 0
        return 2 * NotchLayout.cardPadding + headerHeight + body + more
    }

    /// The tallest the card can be — what the panel reserves room for, so the
    /// notch does not resize every time a session starts or stops waiting.
    static var maxHeight: CGFloat { height(itemCount: maxRows + 1) }

    private var cardHeight: CGFloat { Self.height(itemCount: items.count) }
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
            let maxOffset = max(0, (cardHeight / 2) - NotchLayout.cardCorner - (size.height / 2))
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
                .frame(width: NotchLayout.cardWidth, height: cardHeight)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.t("To do"))
                        .font(Typography.cardTitle)
                        .foregroundStyle(Palette.textPrimary)
                    Spacer(minLength: 0)
                    if !items.isEmpty {
                        Text("\(items.count)")
                            .font(Typography.cardTitle)
                            .foregroundStyle(Palette.watch)
                    }
                }
                .frame(height: Self.headerHeight, alignment: .top)

                if items.isEmpty {
                    Text(L10n.t("Nothing is waiting on you."))
                        .font(Typography.cardBody)
                        .foregroundStyle(secondaryInk)
                        .frame(height: Self.emptyHeight, alignment: .topLeading)
                } else {
                    ForEach(items.prefix(Self.maxRows)) { item in
                        row(item)
                            .frame(height: Self.rowHeight, alignment: .topLeading)
                    }
                    if items.count > Self.maxRows {
                        Text(L10n.t("and \(items.count - Self.maxRows) more — see ⌥⌘S"))
                            .font(Typography.cardBody)
                            .foregroundStyle(secondaryInk)
                            .lineLimit(1)
                            .frame(height: Self.moreHeight, alignment: .topLeading)
                    }
                }
            }
            .padding(NotchLayout.cardPadding)
            .frame(width: NotchLayout.cardWidth, height: cardHeight, alignment: .topLeading)
        }
        .frame(width: NotchLayout.cardWidth, height: cardHeight, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular))
        .overlay {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
                    .strokeBorder(Palette.ringTrack, lineWidth: 1)
            }
        }
    }

    /// Yellow for a question, the colour a waiting session already is in the
    /// notch's rows and on its Wave tab; green for a turn handed back.
    private func row(_ item: SessionPrompt) -> some View {
        HStack(alignment: .top, spacing: Design.px(16)) {
            Circle()
                .fill(item.kind == .blocked ? Palette.watch : Palette.ample)
                .frame(width: Design.px(16), height: Design.px(16))
                .padding(.top, Design.px(10))

            VStack(alignment: .leading, spacing: Design.px(4)) {
                HStack(spacing: Design.px(10)) {
                    Text(item.title)
                        .font(Typography.cardBody.weight(.semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    Text(item.session.detail)
                        .font(Typography.cardBody)
                        .foregroundStyle(secondaryInk)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                Text(item.message)
                    .font(Typography.cardBody)
                    .foregroundStyle(Palette.textPrimary.opacity(0.85))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The whole text is the target, like a session row in the rings'
            // own cards: going there is what a row is for.
            .contentShape(Rectangle())
            .onTapGesture { onGo(item) }

            Spacer(minLength: 0)

            VStack(spacing: Design.px(10)) {
                Button { onGo(item) } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: Design.px(64), height: Design.px(48))
                        .background(Capsule().fill(item.kind == .blocked ? Palette.watch : Palette.ample))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(L10n.t("Go there"))

                Button { onDismiss(item) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(secondaryInk)
                        .frame(width: Design.px(64), height: Design.px(40))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.t("Clear"))
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
