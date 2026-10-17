import UIKit

/// iTerm2-style status bar: connection on the left, directory in the middle, key hints
/// and the clock on the right.
final class StatusBarView: UIView {
    var scale: CGFloat = 1 { didSet { setNeedsLayout() } }
    let leading = UILabel()
    let middle = UILabel()
    let trailing = UILabel()
    let clock = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.15, alpha: 1)
        for label in [leading, middle, trailing, clock] {
            label.textColor = UIColor(white: 0.6, alpha: 1)
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        middle.textAlignment = .center
        trailing.textAlignment = .right
        clock.textColor = UIColor(white: 0.85, alpha: 1)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = scale
        let font = UIFont.systemFont(ofSize: 10 * s)
        for label in [leading, middle, trailing] { label.font = font }
        clock.font = .systemFont(ofSize: 10 * s, weight: .semibold)
        let pad = 10 * s
        let h = bounds.height
        let clockW = ((clock.text ?? "") as NSString).size(withAttributes: [.font: clock.font!]).width + pad
        clock.frame = CGRect(x: bounds.width - pad - clockW, y: 0, width: clockW, height: h)
        let leadW = min(bounds.width * 0.3, ((leading.text ?? "") as NSString).size(withAttributes: [.font: font]).width + pad)
        leading.frame = CGRect(x: pad, y: 0, width: leadW, height: h)
        let trailW = min(bounds.width * 0.4, ((trailing.text ?? "") as NSString).size(withAttributes: [.font: font]).width + pad)
        trailing.frame = CGRect(x: clock.frame.minX - trailW - pad, y: 0, width: trailW, height: h)
        middle.frame = CGRect(x: leading.frame.maxX + pad, y: 0, width: max(0, trailing.frame.minX - leading.frame.maxX - 2 * pad), height: h)
    }
}
