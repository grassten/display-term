import UIKit

/// A menu drawn on the external display and operated with the virtual cursor: the
/// right-click menu, and the option list that stands in for WebKit's `<select>` picker
/// (which ignores synthetic clicks, and would be untouchable on the display anyway).
/// Long lists scroll with two fingers while the pointer is over the menu.
final class ContextMenuView: UIView {
    struct Item {
        let title: String
        var checked = false
        var enabled = true
        let action: () -> Void

        init(title: String, checked: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
            self.title = title
            self.checked = checked
            self.enabled = enabled
            self.action = action
        }
    }

    private let items: [Item]
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let maxHeight: CGFloat
    var onDismiss: (() -> Void)?

    init(items: [Item], scale: CGFloat, maxHeight: CGFloat = .greatestFiniteMagnitude) {
        self.items = items
        self.maxHeight = maxHeight
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.16, alpha: 0.98)
        layer.cornerRadius = 8 * scale
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.5
        layer.shadowRadius = 8 * scale
        layer.shadowOffset = CGSize(width: 0, height: 2 * scale)

        scrollView.showsVerticalScrollIndicator = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        let pad = 4 * scale
        let height = scrollView.heightAnchor.constraint(equalTo: stack.heightAnchor)
        height.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: max(maxHeight - 2 * pad, 26 * scale)),
            height,
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        let hasChecks = items.contains { $0.checked }
        for (index, item) in items.enumerated() {
            let button = UIButton(type: .custom)
            button.tag = index
            let mark = hasChecks ? (item.checked ? "✓  " : "    ") : ""
            button.setTitle(mark + item.title, for: .normal)
            button.setTitleColor(item.enabled ? .white : UIColor(white: 1, alpha: 0.4), for: .normal)
            if item.enabled { button.setBackgroundImage(Self.solidImage(.systemBlue), for: .highlighted) }
            button.titleLabel?.font = .systemFont(ofSize: 13 * scale)
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.contentHorizontalAlignment = .left
            button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12 * scale, bottom: 0, right: 12 * scale)
            button.layer.cornerRadius = 5 * scale
            button.clipsToBounds = true
            button.heightAnchor.constraint(equalToConstant: 26 * scale).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 220 * scale).isActive = true
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 480 * scale).isActive = true
            button.isEnabled = item.enabled
            button.addTarget(self, action: #selector(itemTapped(_:)), for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Scrolls the list so `index` is visible (the selected option of a long `<select>`).
    func reveal(index: Int) {
        guard stack.arrangedSubviews.indices.contains(index) else { return }
        layoutIfNeeded()
        scrollView.scrollRectToVisible(stack.arrangedSubviews[index].frame.insetBy(dx: 0, dy: -60), animated: false)
    }

    func scroll(by dy: CGFloat) {
        var offset = scrollView.contentOffset
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        offset.y = min(max(offset.y + dy, 0), maxY)
        scrollView.setContentOffset(offset, animated: false)
    }

    @objc private func itemTapped(_ sender: UIButton) {
        let item = items[sender.tag]
        guard item.enabled else { return }
        onDismiss?()
        item.action()
    }

    private static func solidImage(_ color: UIColor) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }
}
