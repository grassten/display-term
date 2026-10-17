import UIKit

/// The arrow / hand / I-beam drawn on the external display at the virtual pointer position.
final class CursorView: UIView {
    enum Shape { case arrow, hand, ibeam }

    var shape: Shape = .arrow {
        didSet { if shape != oldValue { updateImage() } }
    }
    var scale: CGFloat = 1 {
        didSet { if scale != oldValue { updateImage() } }
    }

    private let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        imageView.tintColor = .black
        imageView.contentMode = .center
        addSubview(imageView)
        layer.shadowColor = UIColor.white.cgColor
        layer.shadowOpacity = 1
        layer.shadowOffset = .zero
        updateImage()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func shape(forCSSCursor css: String) -> Shape {
        switch css {
        case "pointer", "grab", "grabbing": return .hand
        case "text", "vertical-text": return .ibeam
        default: return .arrow
        }
    }

    private func updateImage() {
        let name: String
        switch shape {
        case .arrow: name = "cursorarrow"
        case .hand: name = "hand.point.up.left.fill"
        case .ibeam: name = "text.cursor"
        }
        let config = UIImage.SymbolConfiguration(pointSize: 22 * scale, weight: .bold)
        imageView.image = UIImage(systemName: name, withConfiguration: config)
        imageView.sizeToFit()
        bounds = CGRect(origin: .zero, size: imageView.bounds.size)
        imageView.frame = bounds
        layer.shadowRadius = 1.2 * scale
    }

    /// Where the hotspot sits inside the view, as a fraction of the size.
    private var hotspotFraction: CGPoint {
        switch shape {
        case .arrow: return CGPoint(x: 0.12, y: 0.05)
        case .hand: return CGPoint(x: 0.38, y: 0.02)
        case .ibeam: return CGPoint(x: 0.5, y: 0.5)
        }
    }

    /// Positions the view so the shape's hotspot is at `point` in the superview.
    func place(at point: CGPoint) {
        let size = bounds.size
        let f = hotspotFraction
        frame = CGRect(origin: CGPoint(x: point.x - size.width * f.x, y: point.y - size.height * f.y), size: size)
    }

    /// A short ring that expands from the hotspot. With no button to feel, this is the
    /// only confirmation that a tap on the phone registered as a click; without it people
    /// tap again, and the second tap becomes a double-click.
    func pulse() {
        let f = hotspotFraction
        let center = CGPoint(x: bounds.width * f.x, y: bounds.height * f.y)
        let radius = 14 * scale
        let ring = CAShapeLayer()
        ring.path = UIBezierPath(arcCenter: .zero, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
        ring.position = center
        ring.fillColor = UIColor.systemBlue.withAlphaComponent(0.25).cgColor
        ring.strokeColor = UIColor.systemBlue.cgColor
        ring.lineWidth = 1.5 * scale
        layer.insertSublayer(ring, at: 0)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.3
        grow.toValue = 1.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.28
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        ring.add(group, forKey: "pulse")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { ring.removeFromSuperlayer() }
    }
}
