import UIKit

/// The tab strip at the top of the display. Pointer hit-testing only; no touch input.
final class TabBarView: UIView {
    enum Hit {
        case tab(Int)
        case newTab
    }

    var scale: CGFloat = 1
    private var tabFrames: [CGRect] = []
    private var plusFrame: CGRect = .zero
    private var labels: [UILabel] = []
    private let plusLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.15, alpha: 1)
        plusLabel.text = "+"
        plusLabel.textAlignment = .center
        plusLabel.textColor = UIColor(white: 0.6, alpha: 1)
        addSubview(plusLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func render(titles: [String], active: Int) {
        while labels.count < titles.count {
            let label = UILabel()
            label.textAlignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.layer.masksToBounds = true
            addSubview(label)
            labels.append(label)
        }
        while labels.count > titles.count { labels.removeLast().removeFromSuperview() }

        let s = scale
        let h = bounds.height
        let maxW = 260 * s
        let font = UIFont.systemFont(ofSize: 10.5 * s, weight: .regular)
        let activeFont = UIFont.systemFont(ofSize: 10.5 * s, weight: .semibold)
        var x: CGFloat = 0
        tabFrames = []
        for (i, title) in titles.enumerated() {
            let label = labels[i]
            let text = "\(i + 1)  \(title)"
            label.text = text
            label.font = i == active ? activeFont : font
            let w = min(maxW, (text as NSString).size(withAttributes: [.font: activeFont]).width + 28 * s)
            let frame = CGRect(x: x, y: 0, width: w, height: h)
            label.frame = frame
            label.backgroundColor = i == active ? .black : .clear
            label.textColor = i == active ? UIColor(white: 0.9, alpha: 1) : UIColor(white: 0.55, alpha: 1)
            tabFrames.append(frame)
            x += w
            // Hairline between tabs.
            label.layer.borderWidth = 0
        }
        plusLabel.font = .systemFont(ofSize: 15 * s)
        plusFrame = CGRect(x: x, y: 0, width: 30 * s, height: h)
        plusLabel.frame = plusFrame
        setNeedsDisplay()
    }

    func hit(_ point: CGPoint) -> Hit? {
        if let i = tabFrames.firstIndex(where: { $0.contains(point) }) { return .tab(i) }
        if plusFrame.contains(point) { return .newTab }
        return nil
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(UIColor(white: 1, alpha: 0.12).cgColor)
        for frame in tabFrames {
            ctx.fill(CGRect(x: frame.maxX - 0.5 * scale, y: 0, width: max(1, scale), height: bounds.height))
        }
        // Active tab accent.
        ctx.setFillColor(UIColor.systemBlue.cgColor)
        if let i = labels.firstIndex(where: { $0.backgroundColor == .black }), tabFrames.indices.contains(i) {
            ctx.fill(CGRect(x: tabFrames[i].minX, y: 0, width: tabFrames[i].width, height: max(1, 2 * scale)))
        }
    }
}
