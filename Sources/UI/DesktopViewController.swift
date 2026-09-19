import UIKit
import Combine

/// Everything drawn on the external display: tab strip, URL line, the page, and a status bar.
/// This scene receives no input; all state comes from BrowserModel.
final class DesktopViewController: UIViewController {
    private let model = BrowserModel.shared
    private var cancellable: AnyCancellable?
    private var renderScheduled = false

    private let topBar = UIView()
    private let tabStack = UIStackView()
    private let urlLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let webContainer = UIView()
    private let bottomBar = UIView()
    private let modeLabel = PaddedLabel()
    private let statusLabel = UILabel()

    private var scale: CGFloat { model.displayUIScale }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        topBar.backgroundColor = UIColor(white: 0.12, alpha: 1)
        tabStack.axis = .horizontal
        tabStack.alignment = .center
        tabStack.distribution = .fill
        urlLabel.textColor = UIColor(white: 0.8, alpha: 1)
        urlLabel.lineBreakMode = .byTruncatingMiddle
        progressView.trackTintColor = .clear
        progressView.progressTintColor = .systemBlue
        webContainer.backgroundColor = .white
        bottomBar.backgroundColor = UIColor(white: 0.12, alpha: 1)
        modeLabel.textColor = .black
        modeLabel.backgroundColor = .systemYellow
        modeLabel.layer.cornerRadius = 4
        modeLabel.clipsToBounds = true
        statusLabel.textColor = UIColor(white: 0.75, alpha: 1)
        statusLabel.lineBreakMode = .byTruncatingTail

        view.addSubview(topBar)
        topBar.addSubview(tabStack)
        topBar.addSubview(urlLabel)
        topBar.addSubview(progressView)
        view.addSubview(webContainer)
        view.addSubview(bottomBar)
        bottomBar.addSubview(modeLabel)
        bottomBar.addSubview(statusLabel)

        cancellable = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRender() }
        render()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let s = scale
        let b = view.bounds
        let tabRow = 30 * s
        let urlRow = 22 * s
        let topH = tabRow + urlRow
        let bottomH = 24 * s

        topBar.frame = CGRect(x: 0, y: 0, width: b.width, height: topH)
        tabStack.spacing = 4 * s
        tabStack.frame = CGRect(x: 8 * s, y: 3 * s, width: b.width - 16 * s, height: tabRow - 6 * s)
        urlLabel.font = .systemFont(ofSize: 12 * s)
        urlLabel.frame = CGRect(x: 10 * s, y: tabRow, width: b.width - 20 * s, height: urlRow - 2 * s)
        progressView.frame = CGRect(x: 0, y: topH - 2 * s, width: b.width, height: 2 * s)

        webContainer.frame = CGRect(x: 0, y: topH, width: b.width, height: b.height - topH - bottomH)
        for sub in webContainer.subviews { sub.frame = webContainer.bounds }

        bottomBar.frame = CGRect(x: 0, y: b.height - bottomH, width: b.width, height: bottomH)
        modeLabel.font = .monospacedSystemFont(ofSize: 11 * s, weight: .bold)
        modeLabel.insets = UIEdgeInsets(top: 2 * s, left: 6 * s, bottom: 2 * s, right: 6 * s)
        modeLabel.sizeToFit()
        modeLabel.frame = CGRect(x: 8 * s, y: (bottomH - modeLabel.bounds.height) / 2,
                                 width: modeLabel.bounds.width, height: modeLabel.bounds.height)
        statusLabel.font = .systemFont(ofSize: 11 * s)
        let sx = modeLabel.frame.maxX + 10 * s
        statusLabel.frame = CGRect(x: sx, y: 0, width: b.width - sx - 8 * s, height: bottomH)
    }

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.renderScheduled = false
            self?.render()
        }
    }

    private func render() {
        let s = scale

        for sub in tabStack.arrangedSubviews { sub.removeFromSuperview() }
        for (index, tab) in model.tabs.enumerated() {
            let active = index == model.activeIndex
            let label = PaddedLabel()
            label.insets = UIEdgeInsets(top: 3 * s, left: 8 * s, bottom: 3 * s, right: 8 * s)
            label.font = .systemFont(ofSize: 12 * s, weight: active ? .semibold : .regular)
            label.textColor = active ? .white : UIColor(white: 0.7, alpha: 1)
            label.backgroundColor = active ? UIColor(white: 0.3, alpha: 1) : UIColor(white: 0.18, alpha: 1)
            label.layer.cornerRadius = 5 * s
            label.clipsToBounds = true
            label.lineBreakMode = .byTruncatingTail
            label.text = "\(index + 1)  \(tab.displayTitle)"
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 260 * s).isActive = true
            tabStack.addArrangedSubview(label)
        }
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabStack.addArrangedSubview(spacer)

        if let tab = model.activeTab {
            urlLabel.text = tab.url?.absoluteString ?? ""
            progressView.progress = Float(tab.progress)
            progressView.isHidden = tab.progress >= 1
            if model.displayAttached {
                WebViewHost.attach(tab.webView, to: webContainer)
            }
        }

        modeLabel.text = model.mode.rawValue
        modeLabel.backgroundColor = model.mode == .insert ? .systemGreen : (model.mode == .hints ? .systemOrange : .systemYellow)
        statusLabel.text = model.statusMessage.isEmpty ? BrowserModel.helpText : model.statusMessage
        view.setNeedsLayout()
    }
}
