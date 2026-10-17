import UIKit
import SwiftTerm

/// Hosts one pane's terminal view with an optional title bar (`user@host — cwd — title`),
/// a dimming overlay when unfocused, and a state banner while not connected.
final class PaneView: UIView {
    let pane: Pane
    var scale: CGFloat = 1 { didSet { setNeedsLayout() } }
    var showsTitleBar = true { didSet { setNeedsLayout() } }
    var dimAmount: CGFloat = 0.4 { didSet { update() } }
    var isActivePane = true { didSet { update() } }

    private let titleBar = UIView()
    private let titleLabel = UILabel()
    private let terminalContainer = UIView()
    private let dimOverlay = UIView()
    private let stateLabel = UILabel()
    private let focusLine = UIView()

    init(pane: Pane) {
        self.pane = pane
        super.init(frame: .zero)
        clipsToBounds = true
        titleBar.backgroundColor = UIColor(white: 0.15, alpha: 1)
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleBar.addSubview(titleLabel)
        addSubview(terminalContainer)
        addSubview(titleBar)
        focusLine.backgroundColor = .systemBlue
        titleBar.addSubview(focusLine)
        dimOverlay.backgroundColor = .black
        dimOverlay.isUserInteractionEnabled = false
        addSubview(dimOverlay)
        stateLabel.textAlignment = .center
        stateLabel.numberOfLines = 2
        stateLabel.textColor = UIColor(white: 0.85, alpha: 1)
        stateLabel.backgroundColor = UIColor(white: 0.1, alpha: 0.85)
        stateLabel.layer.cornerRadius = 6
        stateLabel.clipsToBounds = true
        addSubview(stateLabel)
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Take the terminal view (it may currently live in another window).
    func attachTerminal() {
        if pane.terminalView.superview !== terminalContainer {
            pane.terminalView.removeFromSuperview()
            terminalContainer.addSubview(pane.terminalView)
        }
        setNeedsLayout()
    }

    var terminalFrame: CGRect { terminalContainer.frame }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = bounds
        let titleH = showsTitleBar ? round(18 * scale) : 0
        titleBar.frame = CGRect(x: 0, y: 0, width: b.width, height: titleH)
        titleBar.isHidden = !showsTitleBar
        titleLabel.font = .systemFont(ofSize: 9.5 * scale, weight: .medium)
        titleLabel.frame = titleBar.bounds.insetBy(dx: 8 * scale, dy: 0)
        focusLine.frame = CGRect(x: 0, y: 0, width: b.width, height: max(1, round(1.5 * scale)))
        terminalContainer.frame = CGRect(x: 0, y: titleH, width: b.width, height: b.height - titleH)
        if pane.terminalView.superview === terminalContainer, pane.terminalView.frame != terminalContainer.bounds {
            pane.terminalView.frame = terminalContainer.bounds
        }
        dimOverlay.frame = terminalContainer.frame
        stateLabel.font = .systemFont(ofSize: 11 * scale, weight: .medium)
        let size = stateLabel.sizeThatFits(CGSize(width: b.width - 40 * scale, height: 200))
        stateLabel.frame = CGRect(x: (b.width - size.width - 24 * scale) / 2, y: terminalContainer.frame.minY + 12 * scale,
                                  width: size.width + 24 * scale, height: size.height + 12 * scale)
    }

    func update() {
        titleLabel.text = pane.titleBarText
        titleLabel.textColor = isActivePane ? UIColor(white: 0.85, alpha: 1) : UIColor(white: 0.55, alpha: 1)
        focusLine.isHidden = !isActivePane
        dimOverlay.alpha = isActivePane ? 0 : dimAmount
        switch pane.state {
        case .connected:
            stateLabel.isHidden = true
        default:
            stateLabel.isHidden = false
            stateLabel.text = pane.state.text
        }
        setNeedsLayout()
    }
}
