import SwiftUI

/// What the switcher shows, and what the keyboard moves through.
///
/// A class rather than state inside the view because the panel's key handling
/// lives in AppKit — `SessionFleetWindowController` turns an arrow key into a
/// call on this, and SwiftUI redraws from the published change.
@MainActor
final class SessionFleetViewModel: ObservableObject {
    @Published private(set) var fleet: SessionFleet = .empty
    /// Held by row id, not index — see `SessionFleet.selection(keeping:previousIndex:)`
    /// for why the list moving under a highlight is the normal case here.
    @Published private(set) var selectedID: String?
    /// The clock the elapsed column reads. Ticked by the controller while the
    /// panel is open and left alone when it is not.
    @Published var now: Date = Date()

    var onJump: ((SessionFleet.Row) -> Void)?

    private var selectedIndex: Int {
        fleet.rows.firstIndex { $0.id == selectedID } ?? 0
    }

    func apply(_ fleet: SessionFleet) {
        let index = selectedIndex
        self.fleet = fleet
        selectedID = fleet.selection(keeping: selectedID, previousIndex: index)
            .map { fleet.rows[$0].id }
    }

    /// Walk the flattened order, so ↓ crosses from the last row of one window
    /// into the first of the next without the group headings getting in the way.
    func moveSelection(by offset: Int) {
        guard !fleet.rows.isEmpty else { return }
        let next = selectedIndex + offset
        // Clamped rather than wrapped: at nine sessions the ends of the list
        // are a place you can be, and wrapping loses you halfway down it.
        selectedID = fleet.rows[min(max(0, next), fleet.rows.count - 1)].id
    }

    func select(_ id: String) { selectedID = id }

    func jumpToSelection() {
        guard let selectedID, let row = fleet.rows.first(where: { $0.id == selectedID })
        else { return }
        onJump?(row)
    }
}

/// The switcher panel's contents.
///
/// Deliberately on ordinary system type rather than `Typography`, whose sizes
/// are quoted from the notch's design frame in `Design.px`. This is a panel you
/// open, read and dismiss — it belongs to the same world as a Settings window,
/// not to the thing welded to the screen edge.
struct SessionFleetView: View {
    @ObservedObject var model: SessionFleetViewModel
    /// Shown in the header so the shortcut that opened it is also the shortcut
    /// you learn.
    let shortcut: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Palette.ringTrack)
            if model.fleet.rows.isEmpty {
                empty
            } else {
                list
            }
        }
        .background(Palette.card)
        .foregroundStyle(Palette.textPrimary)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(shortcut)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.textSecondary)
            Text(L10n.t("Active sessions"))
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 12)
            Text(count)
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var count: String {
        let waiting = model.fleet.rows.filter { $0.session.state == .waiting }.count
        let total = model.fleet.rows.count
        // The number that decides whether you keep reading goes first.
        guard waiting > 0 else { return L10n.t("\(total) running") }
        return L10n.t("\(waiting) waiting · \(total) running")
    }

    private var empty: some View {
        Text(L10n.t("No agent is running in a window right now."))
            .font(.system(size: 12))
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var list: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    ForEach(model.fleet.groups) { group in
                        Text(group.heading)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.textSecondary)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                        ForEach(group.rows) { row in
                            SessionFleetRow(row: row, now: model.now,
                                            isSelected: row.id == model.selectedID)
                                .id(row.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    model.select(row.id)
                                    model.jumpToSelection()
                                }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            // Arrow keys move the selection past the bottom of a nine-session
            // list, and a highlight you cannot see is the same as none.
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { scroll.scrollTo(id, anchor: .bottom) }
            }
        }
    }
}

private struct SessionFleetRow: View {
    let row: SessionFleet.Row
    let now: Date
    let isSelected: Bool

    private var session: AgentSession { row.session }

    /// The same colours the notch gives these states, so a row means the same
    /// thing in both places.
    private var stateColor: Color {
        switch session.state {
        case .busy:    return Palette.textPrimary
        case .waiting: return Palette.watch
        case .success: return Palette.ample
        case .idle:    return Palette.textSecondary
        }
    }

    private var stateWord: String {
        switch session.state {
        case .busy:    return L10n.t("working")
        case .waiting: return L10n.t("waiting")
        case .success: return L10n.t("complete")
        case .idle:    return L10n.t("idle")
        }
    }

    /// While blocked, what it is blocked on matters more than where it lives —
    /// the same rule the tooltip's rows follow.
    private var detail: String {
        if session.state == .waiting, let waitingFor = session.waitingFor, !waitingFor.isEmpty {
            return waitingFor
        }
        return session.detail
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(stateColor)
                // Idle windows are listed so you can get back to them, not to
                // be looked at; a hollow dot keeps them off the eye's path.
                .opacity(session.state == .idle ? 0.35 : 1)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(stateWord)
                .font(.system(size: 11))
                .foregroundStyle(stateColor)
            Text(ElapsedCopy.text(since: session.since, now: now))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(isSelected ? Palette.ringTrack : Color.clear)
    }
}
