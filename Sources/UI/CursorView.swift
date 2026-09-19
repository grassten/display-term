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

    /// Positions the view so the shape's hotspot is at `point` in the superview.
    func place(at point: CGPoint) {
        let size = bounds.size
        let origin: CGPoint
        switch shape {
        case .arrow: origin = CGPoint(x: point.x - size.width * 0.12, y: point.y - size.height * 0.05)
        case .hand: origin = CGPoint(x: point.x - size.width * 0.38, y: point.y - size.height * 0.02)
        case .ibeam: origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        }
        frame = CGRect(origin: origin, size: size)
    }
}
