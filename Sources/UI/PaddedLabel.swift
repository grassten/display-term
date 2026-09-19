import UIKit

final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fitted = super.sizeThatFits(size)
        return CGSize(width: fitted.width + insets.left + insets.right, height: fitted.height + insets.top + insets.bottom)
    }
}

enum WebViewHost {
    /// Moves a web view into `container`, evicting any other web view already there.
    static func attach(_ webView: UIView, to container: UIView) {
        for sub in container.subviews where sub !== webView { sub.removeFromSuperview() }
        if webView.superview !== container {
            webView.removeFromSuperview()
            container.addSubview(webView)
        }
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }
}
