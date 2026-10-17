import UIKit

/// How a pane is split. iTerm2 vocabulary: a *vertical* split puts panes side by side
/// (⌘D), a *horizontal* split stacks them (⌘⇧D).
enum SplitAxis: String, Codable {
    case vertical, horizontal
}

enum Direction: String {
    case left, right, up, down
}

struct DividerLayout {
    let splitID: UUID
    let axis: SplitAxis
    /// The thin visible line.
    let frame: CGRect
    /// The whole split node's frame; the divider's position within it is the ratio.
    let splitFrame: CGRect
}

struct PaneLayout {
    var frames: [UUID: CGRect] = [:]
    var dividers: [DividerLayout] = []
}

/// A tab's panes as a binary split tree, as in iTerm2 and tmux.
indirect enum PaneNode {
    case leaf(Pane)
    case split(id: UUID, axis: SplitAxis, ratio: CGFloat, first: PaneNode, second: PaneNode)

    var leaves: [Pane] {
        switch self {
        case .leaf(let pane): return [pane]
        case .split(_, _, _, let a, let b): return a.leaves + b.leaves
        }
    }

    func contains(_ paneID: UUID) -> Bool {
        leaves.contains { $0.id == paneID }
    }

    /// Replace the leaf `paneID` with a split holding it and `newPane`.
    func splitting(_ paneID: UUID, axis: SplitAxis, newPane: Pane) -> PaneNode {
        switch self {
        case .leaf(let pane):
            guard pane.id == paneID else { return self }
            return .split(id: UUID(), axis: axis, ratio: 0.5, first: .leaf(pane), second: .leaf(newPane))
        case .split(let id, let ax, let ratio, let a, let b):
            return .split(id: id, axis: ax, ratio: ratio,
                          first: a.splitting(paneID, axis: axis, newPane: newPane),
                          second: b.splitting(paneID, axis: axis, newPane: newPane))
        }
    }

    /// Remove a leaf; its sibling takes the parent's place. Nil when this node was the leaf.
    func removing(_ paneID: UUID) -> PaneNode? {
        switch self {
        case .leaf(let pane):
            return pane.id == paneID ? nil : self
        case .split(let id, let axis, let ratio, let a, let b):
            if case .leaf(let p) = a, p.id == paneID { return b }
            if case .leaf(let p) = b, p.id == paneID { return a }
            return .split(id: id, axis: axis, ratio: ratio,
                          first: a.removing(paneID) ?? a, second: b.removing(paneID) ?? b)
        }
    }

    /// The pane iTerm2 focuses when `paneID` closes: the sibling before it in its split view
    /// (after it when it is first), then that sibling's first pane. iTerm2 keeps consecutive
    /// same-axis splits in one split view, so the sibling search walks up that run.
    func successor(ofClosing paneID: UUID) -> Pane? {
        let chain = ancestry(of: paneID)
        guard let inner = chain.last else { return nil }
        for step in chain.reversed() {
            guard step.axis == inner.axis else { break }
            if !step.leafIsFirst { return step.first.lastMember(along: inner.axis).leaves.first }
        }
        return inner.second.leaves.first
    }

    private func ancestry(of paneID: UUID) -> [(axis: SplitAxis, first: PaneNode, second: PaneNode, leafIsFirst: Bool)] {
        guard case .split(_, let axis, _, let a, let b) = self else { return [] }
        if a.contains(paneID) { return [(axis, a, b, true)] + a.ancestry(of: paneID) }
        if b.contains(paneID) { return [(axis, a, b, false)] + b.ancestry(of: paneID) }
        return []
    }

    /// The last item of the same-axis run this node belongs to, as iTerm2's split view would list it.
    private func lastMember(along axis: SplitAxis) -> PaneNode {
        if case .split(_, let ax, _, _, let b) = self, ax == axis { return b.lastMember(along: axis) }
        return self
    }

    func updatingRatio(of splitID: UUID, to newRatio: CGFloat) -> PaneNode {
        switch self {
        case .leaf: return self
        case .split(let id, let axis, let ratio, let a, let b):
            if id == splitID {
                return .split(id: id, axis: axis, ratio: min(0.9, max(0.1, newRatio)), first: a, second: b)
            }
            return .split(id: id, axis: axis, ratio: ratio,
                          first: a.updatingRatio(of: splitID, to: newRatio), second: b.updatingRatio(of: splitID, to: newRatio))
        }
    }

    /// The split nodes on the way to a leaf, innermost last, with which side the leaf is on.
    func path(to paneID: UUID) -> [(splitID: UUID, axis: SplitAxis, ratio: CGFloat, leafIsFirst: Bool)] {
        switch self {
        case .leaf: return []
        case .split(let id, let axis, let ratio, let a, let b):
            if a.contains(paneID) { return [(id, axis, ratio, true)] + a.path(to: paneID) }
            if b.contains(paneID) { return [(id, axis, ratio, false)] + b.path(to: paneID) }
            return []
        }
    }

    /// Divide `rect` among the leaves. `divider` is the visible line's thickness.
    func layout(in rect: CGRect, divider: CGFloat, into layout: inout PaneLayout) {
        switch self {
        case .leaf(let pane):
            layout.frames[pane.id] = rect
        case .split(let id, let axis, let ratio, let a, let b):
            switch axis {
            case .vertical:
                let w = (rect.width - divider) * ratio
                let first = CGRect(x: rect.minX, y: rect.minY, width: floor(w), height: rect.height)
                let line = CGRect(x: first.maxX, y: rect.minY, width: divider, height: rect.height)
                let second = CGRect(x: line.maxX, y: rect.minY, width: rect.maxX - line.maxX, height: rect.height)
                layout.dividers.append(DividerLayout(splitID: id, axis: axis, frame: line, splitFrame: rect))
                a.layout(in: first, divider: divider, into: &layout)
                b.layout(in: second, divider: divider, into: &layout)
            case .horizontal:
                let h = (rect.height - divider) * ratio
                let first = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: floor(h))
                let line = CGRect(x: rect.minX, y: first.maxY, width: rect.width, height: divider)
                let second = CGRect(x: rect.minX, y: line.maxY, width: rect.width, height: rect.maxY - line.maxY)
                layout.dividers.append(DividerLayout(splitID: id, axis: axis, frame: line, splitFrame: rect))
                a.layout(in: first, divider: divider, into: &layout)
                b.layout(in: second, divider: divider, into: &layout)
            }
        }
    }
}

/// A tab: a tree of panes, one of which has keyboard focus.
final class Tab {
    let id = UUID()
    var customTitle: String?
    private(set) var root: PaneNode
    private(set) var focusedPaneID: UUID
    var maximizedPaneID: UUID?

    init(pane: Pane) {
        root = .leaf(pane)
        focusedPaneID = pane.id
    }

    init(root: PaneNode, focusedPaneID: UUID?) {
        self.root = root
        self.focusedPaneID = focusedPaneID.flatMap { id in root.contains(id) ? id : nil } ?? root.leaves[0].id
    }

    var panes: [Pane] { root.leaves }
    var focusedPane: Pane? { panes.first { $0.id == focusedPaneID } }

    var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        return focusedPane?.displayTitle ?? "Terminal"
    }

    func focus(_ pane: Pane) {
        guard root.contains(pane.id) else { return }
        focusedPaneID = pane.id
    }

    func split(_ pane: Pane, axis: SplitAxis, with newPane: Pane) {
        root = root.splitting(pane.id, axis: axis, newPane: newPane)
        focusedPaneID = newPane.id
        maximizedPaneID = nil
    }

    /// Returns false when the pane was the last one (close the tab instead).
    func remove(_ pane: Pane) -> Bool {
        let successor = root.successor(ofClosing: pane.id)
        guard let newRoot = root.removing(pane.id) else { return false }
        root = newRoot
        if maximizedPaneID == pane.id { maximizedPaneID = nil }
        if focusedPaneID == pane.id {
            focusedPaneID = successor?.id ?? root.leaves.first?.id ?? focusedPaneID
        }
        return true
    }

    func layout(in rect: CGRect, divider: CGFloat) -> PaneLayout {
        var layout = PaneLayout()
        if let maximizedPaneID, let pane = panes.first(where: { $0.id == maximizedPaneID }) {
            layout.frames[pane.id] = rect
            return layout
        }
        root.layout(in: rect, divider: divider, into: &layout)
        return layout
    }

    /// The pane adjacent to the focused one in `direction`, by geometry.
    func neighbour(_ direction: Direction) -> Pane? {
        var layout = PaneLayout()
        root.layout(in: CGRect(x: 0, y: 0, width: 1000, height: 1000), divider: 0, into: &layout)
        guard let from = layout.frames[focusedPaneID] else { return nil }
        var best: (Pane, CGFloat)?
        for pane in panes where pane.id != focusedPaneID {
            guard let f = layout.frames[pane.id] else { continue }
            let adjacent: Bool
            switch direction {
            case .left: adjacent = abs(f.maxX - from.minX) < 1 && f.maxY > from.minY && f.minY < from.maxY
            case .right: adjacent = abs(f.minX - from.maxX) < 1 && f.maxY > from.minY && f.minY < from.maxY
            case .up: adjacent = abs(f.maxY - from.minY) < 1 && f.maxX > from.minX && f.minX < from.maxX
            case .down: adjacent = abs(f.minY - from.maxY) < 1 && f.maxX > from.minX && f.minX < from.maxX
            }
            guard adjacent else { continue }
            let d = hypot(f.midX - from.midX, f.midY - from.midY)
            if best == nil || d < best!.1 { best = (pane, d) }
        }
        return best?.0
    }

    func setRatio(of splitID: UUID, to ratio: CGFloat) {
        root = root.updatingRatio(of: splitID, to: ratio)
    }

    /// Move the divider nearest the focused pane along `direction` by `step` (0...1).
    func moveDivider(_ direction: Direction, step: CGFloat = 0.05) {
        let axis: SplitAxis = (direction == .left || direction == .right) ? .vertical : .horizontal
        guard let node = root.path(to: focusedPaneID).last(where: { $0.axis == axis }) else { return }
        let grow = (direction == .right || direction == .down) == node.leafIsFirst
        root = root.updatingRatio(of: node.splitID, to: node.ratio + (grow ? step : -step))
    }
}
