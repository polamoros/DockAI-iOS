// tRPC: none
import UIKit

/// The keys a phone keyboard does not have, as a row above it: Esc, a sticky
/// Ctrl, Tab, the arrows, and the characters a shell wants that sit two
/// layers deep on the iOS keyboard. Used by the terminal and by the browser
/// viewer (which has no Ctrl and no characters).
final class KeyAccessoryBar: UIInputView {
    enum Key: Hashable {
        case esc, ctrl, tab, up, down, left, right, text(String), paste, dismiss
    }

    var onKey: ((Key) -> Void)?
    private var ctrlButton: UIButton?

    init(keys: [Key]) {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 44), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth]

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 44),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -6),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -12),
        ])

        for key in keys {
            let b = UIButton(type: .system)
            var cfg = UIButton.Configuration.gray()
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
            switch key {
            case .esc: cfg.title = "Esc"
            case .ctrl: cfg.title = "Ctrl"
            case .tab: cfg.title = "Tab"
            case .up: cfg.image = UIImage(systemName: "arrow.up")
            case .down: cfg.image = UIImage(systemName: "arrow.down")
            case .left: cfg.image = UIImage(systemName: "arrow.left")
            case .right: cfg.image = UIImage(systemName: "arrow.right")
            case .text(let s): cfg.title = s
            case .paste: cfg.image = UIImage(systemName: "doc.on.clipboard")
            case .dismiss: cfg.image = UIImage(systemName: "keyboard.chevron.compact.down")
            }
            cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs
                a.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .medium)
                return a
            }
            b.configuration = cfg
            b.accessibilityLabel = Self.label(for: key)
            b.addAction(UIAction { [weak self] _ in
                UIDevice.current.playInputClick()
                self?.onKey?(key)
            }, for: .touchUpInside)
            if key == .ctrl { ctrlButton = b }
            stack.addArrangedSubview(b)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Ctrl is sticky: it lights up until the next key consumes it.
    func setCtrl(_ on: Bool) {
        guard let b = ctrlButton else { return }
        var cfg = on ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
        cfg.title = "Ctrl"
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        b.configuration = cfg
        b.accessibilityValue = on ? "On" : "Off"
    }

    private static func label(for key: Key) -> String {
        switch key {
        case .esc: "Escape"; case .ctrl: "Control"; case .tab: "Tab"
        case .up: "Up arrow"; case .down: "Down arrow"; case .left: "Left arrow"; case .right: "Right arrow"
        case .text(let s): s; case .paste: "Paste"; case .dismiss: "Hide keyboard"
        }
    }
}

extension KeyAccessoryBar: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
