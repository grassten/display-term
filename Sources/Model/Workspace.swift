import UIKit
import Combine

/// The one window: tabs, each a tree of panes. Shared by the phone and display scenes.
final class Workspace: ObservableObject {
    unowned let state: AppState
    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var activeIndex = 0
    private var restoring = false

    init(state: AppState) {
        self.state = state
        restore()
    }

    var activeTab: Tab? { tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil }
    var focusedPane: Pane? { activeTab?.focusedPane }
    var allPanes: [Pane] { tabs.flatMap(\.panes) }

    /// Published after any structural or focus change, so both scenes re-render.
    func changed() {
        objectWillChange.send()
        if !restoring { save() }
    }

    // MARK: Tabs

    @discardableResult
    func newTab(profile: Profile? = nil) -> Tab? {
        guard let profile = profile ?? focusedPane?.profile ?? state.profiles.defaultProfile else { return nil }
        let pane = makePane(profile: profile)
        let tab = Tab(pane: pane)
        tabs.append(tab)
        activeIndex = tabs.count - 1
        pane.connect()
        changed()
        return tab
    }

    func closeTab(_ tab: Tab) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.panes.forEach { $0.close() }
        tabs.remove(at: i)
        activeIndex = min(max(0, activeIndex > i ? activeIndex - 1 : activeIndex), max(0, tabs.count - 1))
        changed()
    }

    func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeIndex = index
        changed()
    }

    func nextTab() { guard tabs.count > 1 else { return }; selectTab((activeIndex + 1) % tabs.count) }
    func previousTab() { guard tabs.count > 1 else { return }; selectTab((activeIndex - 1 + tabs.count) % tabs.count) }

    func moveTab(by delta: Int) {
        let target = activeIndex + delta
        guard tabs.indices.contains(target) else { return }
        tabs.swapAt(activeIndex, target)
        activeIndex = target
        changed()
    }

    // MARK: Panes

    func split(_ axis: SplitAxis) {
        guard let tab = activeTab, let focused = tab.focusedPane else { newTab(); return }
        let pane = makePane(profile: focused.profile)
        tab.split(focused, axis: axis, with: pane)
        pane.connect()
        changed()
    }

    func closeFocusedPane() {
        guard let tab = activeTab, let pane = tab.focusedPane else { return }
        if tab.panes.count == 1 {
            closeTab(tab)
            return
        }
        pane.close()
        _ = tab.remove(pane)
        changed()
    }

    func focus(_ pane: Pane) {
        for (i, tab) in tabs.enumerated() where tab.panes.contains(where: { $0.id == pane.id }) {
            activeIndex = i
            tab.focus(pane)
            changed()
            return
        }
    }

    func focusPane(_ direction: Direction) {
        guard let tab = activeTab, let next = tab.neighbour(direction) else { return }
        tab.focus(next)
        changed()
    }

    func cyclePane(by delta: Int) {
        guard let tab = activeTab, tab.panes.count > 1,
              let i = tab.panes.firstIndex(where: { $0.id == tab.focusedPaneID }) else { return }
        let n = tab.panes.count
        tab.focus(tab.panes[(i + delta + n) % n])
        changed()
    }

    func toggleMaximize() {
        guard let tab = activeTab, tab.panes.count > 1 else { return }
        tab.maximizedPaneID = tab.maximizedPaneID == nil ? tab.focusedPaneID : nil
        changed()
    }

    func moveDivider(_ direction: Direction) {
        activeTab?.moveDivider(direction)
        changed()
    }

    func setRatio(tab: Tab, splitID: UUID, ratio: CGFloat) {
        tab.setRatio(of: splitID, to: ratio)
        changed()
    }

    // MARK: Lifecycle

    /// Back in the foreground: panes that lost their connection while suspended reconnect now.
    func resumeAfterForeground() {
        allPanes.forEach { $0.resumeIfNeeded() }
    }

    func reconnectFocused() {
        focusedPane?.reconnectNow()
    }

    private func makePane(profile: Profile) -> Pane {
        let serial = UserDefaults.standard.integer(forKey: "nextPaneSerial") + 1
        UserDefaults.standard.set(serial, forKey: "nextPaneSerial")
        return attach(Pane(profile: profile, tmuxSession: "dt-\(serial)"))
    }

    private func attach(_ pane: Pane) -> Pane {
        pane.onChange = { [weak self] in self?.objectWillChange.send() }
        return pane
    }

    // MARK: Persistence (Application Support/workspace.json)

    private struct Saved: Codable {
        struct Node: Codable {
            var pane: SavedPane?
            var split: SplitAxis?
            var ratio: CGFloat?
            var children: [Node]?
        }
        struct SavedPane: Codable {
            var id: UUID
            var profile: UUID
            var tmux: String
        }
        struct SavedTab: Codable {
            var title: String?
            var focused: UUID?
            var root: Node
        }
        var tabs: [SavedTab]
        var active: Int
    }

    private static var url: URL { AppFiles.applicationSupport.appendingPathComponent("workspace.json") }

    private func save() {
        func node(_ n: PaneNode) -> Saved.Node {
            switch n {
            case .leaf(let p):
                return Saved.Node(pane: .init(id: p.id, profile: p.profile.id, tmux: p.tmuxSession))
            case .split(_, let axis, let ratio, let a, let b):
                return Saved.Node(split: axis, ratio: ratio, children: [node(a), node(b)])
            }
        }
        let saved = Saved(tabs: tabs.map { .init(title: $0.customTitle, focused: $0.focusedPaneID, root: node($0.root)) },
                          active: activeIndex)
        AppFiles.writeJSON(saved, to: Self.url)
    }

    private func restore() {
        guard let saved = AppFiles.readJSON(Saved.self, at: Self.url), !saved.tabs.isEmpty else { return }
        restoring = true
        defer { restoring = false }
        func node(_ n: Saved.Node) -> PaneNode? {
            if let p = n.pane {
                guard let profile = state.profiles.profile(id: p.profile) else { return nil }
                return .leaf(attach(Pane(id: p.id, profile: profile, tmuxSession: p.tmux)))
            }
            guard let axis = n.split, let children = n.children, children.count == 2 else { return nil }
            let f = children[0], s = children[1]
            switch (node(f), node(s)) {
            case (let a?, let b?): return .split(id: UUID(), axis: axis, ratio: n.ratio ?? 0.5, first: a, second: b)
            case (let a?, nil): return a
            case (nil, let b?): return b
            default: return nil
            }
        }
        for t in saved.tabs {
            guard let root = node(t.root) else { continue }
            let tab = Tab(root: root, focusedPaneID: t.focused)
            tab.customTitle = t.title
            tabs.append(tab)
        }
        activeIndex = min(saved.active, max(0, tabs.count - 1))
        for pane in allPanes where pane.profile.connectOnLaunch {
            pane.connect()
        }
    }
}
