import UIKit
import SwiftUI

// Native UI component, not a complete scanner. Wire onOperation to the editor.
// Geometry and ordering are version-scoped static recoveries, not a claim of
// measured visual equivalence on a modern iPhone. No original artwork is bundled.
@available(iOS 15.0, *)
public final class RecoveredEditorToolbar: UIView {
    public typealias Contract = RecoveredEditorToolbarContract
    public typealias Operation = Contract.Operation
    public var onOperation: ((Operation) -> Void)?

    private let titleForKey: (String) -> String
    private let imageForName: (String) -> UIImage?
    private var accent: UIColor
    private var surface: UIColor
    private var mutedInk = UIColor.secondaryLabel
    private let strip = UIScrollView()
    private let content = UIView()
    private let trailingPanel = UIView()
    private let fadeView = UIView()
    private let fade = CAGradientLayer()
    private let done = UIButton(type: .system)
    private var buttons: [(Operation, UIButton)] = []
    private var spec = Contract.layout(.processed)
    private var isEnabled = true
    private var selected: Set<Operation> = []
    private var showTitles = true

    public init(titleForKey: @escaping (String) -> String,
                imageForName: @escaping (String) -> UIImage?,
                accent: UIColor, surface: UIColor) {
        self.titleForKey = titleForKey
        self.imageForName = imageForName
        self.accent = accent
        self.surface = surface
        super.init(frame: .zero)
        backgroundColor = surface
        strip.backgroundColor = .clear
        strip.bounces = false
        strip.showsHorizontalScrollIndicator = false
        strip.showsVerticalScrollIndicator = false
        strip.contentInsetAdjustmentBehavior = .never
        addSubview(strip)
        strip.addSubview(content)
        trailingPanel.backgroundColor = surface
        addSubview(trailingPanel)
        fadeView.isUserInteractionEnabled = false
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fadeView.layer.addSublayer(fade)
        addSubview(fadeView)
        done.backgroundColor = accent
        done.tintColor = .white
        done.layer.cornerRadius = 4
        done.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold), forImageIn: .normal)
        done.accessibilityLabel = titleForKey("Save")
        done.setImage(imageForName("ic_done_24px") ?? UIImage(systemName: "checkmark"), for: .normal)
        done.addAction(UIAction { [weak self] _ in
            guard let self = self, self.isEnabled, let action = self.spec.separateDone else { return }
            self.onOperation?(action)
        }, for: .touchUpInside)
        addSubview(done)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use the programmatic initializer.") }

    public func configure(layout: Contract.Layout, referenceMode: Int = 0,
                          viewType: Int = 0, showTitles: Bool = true) {
        spec = Contract.layout(layout, referenceMode: referenceMode, viewType: viewType)
        // The bridge retains historical initializer defaults. A configured editor
        // uses the shared app palette without changing its geometry/action contract.
        accent = UIColor(ScannerAppearance.accent)
        surface = UIColor(ScannerAppearance.surface)
        mutedInk = UIColor(ScannerAppearance.mutedInk)
        backgroundColor = surface
        trailingPanel.backgroundColor = surface
        done.backgroundColor = accent
        self.showTitles = showTitles
        selected.removeAll()
        strip.setContentOffset(.zero, animated: false)
        rebuild()
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        done.isEnabled = enabled
        for (_, button) in buttons { button.isEnabled = enabled }
    }

    public func setSelected(_ isSelected: Bool, for operation: Operation) {
        if isSelected { selected.insert(operation) } else { selected.remove(operation) }
        for (item, button) in buttons where item == operation { apply(operation, to: button) }
    }

    private func rebuild() {
        for (_, button) in buttons { button.removeFromSuperview() }
        buttons = spec.items.map { operation in
            let button = UIButton(type: .system)
            apply(operation, to: button)
            button.addAction(UIAction { [weak self] _ in
                guard let self = self, self.isEnabled else { return }
                self.onOperation?(operation)
            }, for: .touchUpInside)
            content.addSubview(button)
            return (operation, button)
        }
        let hasDone = spec.separateDone != nil
        trailingPanel.isHidden = !hasDone
        fadeView.isHidden = !hasDone
        done.isHidden = !hasDone
        strip.isScrollEnabled = hasDone
        setNeedsLayout()
    }

    private func apply(_ operation: Operation, to button: UIButton) {
        guard let descriptor = Contract.descriptors[operation] else { return }
        let key = selected.contains(operation)
            ? descriptor.selectedTitleKey ?? descriptor.localizedTitleKey
            : descriptor.localizedTitleKey
        var appearance = UIButton.Configuration.plain()
        appearance.image = descriptor.referenceImageName.flatMap(imageForName)
        appearance.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        appearance.imagePlacement = .top
        appearance.imagePadding = 4
        appearance.contentInsets = .zero
        appearance.titleAlignment = .center
        appearance.titleLineBreakMode = .byTruncatingTail
        let iconColor = selected.contains(operation) ? accent : UIColor(white: 0.12, alpha: 1)
        let titleColor = selected.contains(operation) ? accent : mutedInk
        // Explicit transformers keep the bridge's legacy tint from recoloring
        // captions or selected controls, and still distinguish disabled actions.
        appearance.imageColorTransformer = UIConfigurationColorTransformer { [weak button] _ in
            iconColor.withAlphaComponent(button?.isEnabled == false ? 0.3 : 1)
        }
        if showTitles, let key = key { appearance.title = titleForKey(key) }
        appearance.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { [weak button] incoming in
            var result = incoming
            result.font = UIFont.preferredFont(forTextStyle: .caption2)
            result.foregroundColor = titleColor.withAlphaComponent(button?.isEnabled == false ? 0.3 : 1)
            return result
        }
        button.configuration = appearance
        button.isEnabled = isEnabled
        button.isSelected = selected.contains(operation)
        button.accessibilityLabel = key.map(titleForKey) ?? descriptor.nativeAction
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(0, bounds.width)
        if spec.separateDone != nil {
            // Native: cells 65x50; trailing panel 76x50; confirmation 56x36.
            let panelWidth = min(76, width)
            let viewport = max(0, width - panelWidth)
            strip.frame = CGRect(x: 0, y: 0, width: viewport, height: 50)
            content.frame = CGRect(x: 0, y: 0, width: CGFloat(buttons.count) * 65, height: 50)
            for (index, pair) in buttons.enumerated() {
                pair.1.frame = CGRect(x: CGFloat(index) * 65, y: 0, width: 65, height: 50)
            }
            trailingPanel.frame = CGRect(x: viewport, y: 0, width: panelWidth, height: 50)
            // Catalog reference: 90x150 pixels at 3x = 30x50 points.
            fadeView.frame = CGRect(x: max(0, viewport - 30), y: 0, width: min(30, viewport), height: 50)
            done.frame = CGRect(x: max(0, width - 66), y: 7, width: min(56, width), height: 36)
        } else {
            strip.frame = bounds
            content.frame = bounds
            let frames = Contract.referenceFrames(width: Double(width), height: Double(bounds.height), itemCount: buttons.count)
            for (pair, frame) in zip(buttons, frames) {
                pair.1.frame = CGRect(x: CGFloat(frame.x), y: CGFloat(frame.y),
                                     width: CGFloat(frame.width), height: CGFloat(frame.height))
            }
        }
        strip.contentSize = content.bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = fadeView.bounds
        let color = surface.resolvedColor(with: traitCollection)
        fade.colors = [color.withAlphaComponent(0).cgColor, color.cgColor]
        CATransaction.commit()
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) { setNeedsLayout() }
    }
}
