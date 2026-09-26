// tRPC: none
import SwiftUI
import UIKit

/// The remote screen: the framebuffer on a layer inside a zooming scroll
/// view, and the gestures that turn touches into RFB pointer and key events.
///
/// The display is shared with the agent and is not resized by this view
/// (see BrowserTabView): the viewer adapts instead. Fit shows all of it;
/// Zoom shows it one remote pixel to one point, panned with two fingers.
///
/// - tap: left click
/// - two-finger tap: right click
/// - one-finger drag: scroll the page (wheel notches)
/// - long press, then drag: press, drag, release (select text, move sliders)
/// - pinch, two-finger drag: zoom and pan the view
final class RFBScreenView: UIScrollView, UIScrollViewDelegate, UIKeyInput {
    weak var client: RFBClient?
    var zoomed = false { didSet { if oldValue != zoomed { applyZoom(animated: true) } } }

    private let canvas = UIView()
    private var imageSize: CGSize = .zero
    private var wheelCarry: CGPoint = .zero
    private var keyboardBar: KeyAccessoryBar?

    // UITextInputTraits: a password field on a site must reach it verbatim.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .black
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bouncesZoom = true
        maximumZoomScale = 4
        contentInsetAdjustmentBehavior = .never
        // One finger belongs to the remote page; two move this view.
        panGestureRecognizer.minimumNumberOfTouches = 2
        canvas.layer.magnificationFilter = .linear
        canvas.layer.minificationFilter = .trilinear
        addSubview(canvas)

        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        let twoTap = UITapGestureRecognizer(target: self, action: #selector(onTwoFingerTap(_:)))
        twoTap.numberOfTouchesRequired = 2
        let drag = UIPanGestureRecognizer(target: self, action: #selector(onScrollDrag(_:)))
        drag.maximumNumberOfTouches = 1
        let press = UILongPressGestureRecognizer(target: self, action: #selector(onPressDrag(_:)))
        press.minimumPressDuration = 0.4
        drag.require(toFail: press)
        tap.require(toFail: twoTap)
        for g in [tap, twoTap, drag, press] { canvas.addGestureRecognizer(g) }
        canvas.isUserInteractionEnabled = true

        let bar = KeyAccessoryBar(keys: [.esc, .tab, .left, .up, .down, .right, .paste, .dismiss])
        bar.onKey = { [weak self] key in self?.accessoryKey(key) }
        keyboardBar = bar
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Frames

    func show(_ image: CGImage) {
        let size = CGSize(width: image.width, height: image.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.layer.contents = image
        CATransaction.commit()
        if size != imageSize {
            imageSize = size
            zoomScale = 1
            canvas.frame = CGRect(origin: .zero, size: size)
            contentSize = size
            applyZoom(animated: false)
        }
    }

    private var lastBoundsSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard imageSize != .zero else { return }
        // Refit only when the view itself changed size (rotation, full
        // screen), not on every scroll — a pinch the person made stays.
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            applyZoom(animated: false)
        }
        center()
    }

    private var fitScale: CGFloat {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0 else { return 1 }
        return min(bounds.width / imageSize.width, bounds.height / imageSize.height)
    }

    private func applyZoom(animated: Bool) {
        guard imageSize != .zero else { return }
        minimumZoomScale = min(fitScale, 1)
        setZoomScale(zoomed ? max(1, fitScale) : fitScale, animated: animated)
        center()
    }

    /// Keep the frame centred while it is smaller than the view.
    private func center() {
        let w = canvas.frame.width, h = canvas.frame.height
        let dx = max(0, (bounds.width - w) / 2), dy = max(0, (bounds.height - h) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

    // MARK: Pointer

    /// Canvas coordinates are framebuffer pixels: the canvas is the image's
    /// size and the scroll view's zoom is a transform on it.
    private func point(_ g: UIGestureRecognizer) -> CGPoint { g.location(in: canvas) }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        client?.click(point(g))
    }

    @objc private func onTwoFingerTap(_ g: UITapGestureRecognizer) {
        client?.click(point(g), button: 4)
    }

    @objc private func onScrollDrag(_ g: UIPanGestureRecognizer) {
        let p = point(g)
        switch g.state {
        case .began:
            wheelCarry = .zero
            client?.pointer(p, mask: 0)
        case .changed:
            let t = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            wheelCarry.x += t.x
            wheelCarry.y += t.y
            // A notch per 24 points: finger up scrolls the page down.
            let notch: CGFloat = 24
            var events: [UInt8] = []
            while wheelCarry.y <= -notch { events.append(16); wheelCarry.y += notch }
            while wheelCarry.y >= notch { events.append(8); wheelCarry.y -= notch }
            while wheelCarry.x <= -notch { events.append(64); wheelCarry.x += notch }
            while wheelCarry.x >= notch { events.append(32); wheelCarry.x -= notch }
            if !events.isEmpty {
                for e in events { client?.wheel(p, button: e) }
            }
        default:
            break
        }
    }

    @objc private func onPressDrag(_ g: UILongPressGestureRecognizer) {
        let p = point(g)
        switch g.state {
        case .began:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            client?.pointer(p, mask: 0)
            client?.pointer(p, mask: 1)
        case .changed:
            client?.pointer(p, mask: 1)
        case .ended, .cancelled, .failed:
            client?.pointer(p, mask: 0)
        default:
            break
        }
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { keyboardBar }

    var hasText: Bool { true }

    func insertText(_ text: String) {
        client?.type(text)
    }

    func deleteBackward() {
        client?.tap(Keysym.backspace)
    }

    private func accessoryKey(_ key: KeyAccessoryBar.Key) {
        Task { @MainActor in
            switch key {
            case .esc: client?.tap(Keysym.escape)
            case .tab: client?.tap(Keysym.tab)
            case .up: client?.tap(Keysym.up)
            case .down: client?.tap(Keysym.down)
            case .left: client?.tap(Keysym.left)
            case .right: client?.tap(Keysym.right)
            case .paste:
                if let text = UIPasteboard.general.string { await client?.pasteTyping(text) }
            case .dismiss: _ = resignFirstResponder()
            case .ctrl, .text: break
            }
        }
    }

    /// A hardware keyboard's keys that are not text.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let code = press.key?.keyCode, let sym = Self.special[code] else { unhandled.insert(press); continue }
            client?.tap(sym)
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    private static let special: [UIKeyboardHIDUsage: UInt32] = [
        .keyboardEscape: Keysym.escape,
        .keyboardUpArrow: Keysym.up,
        .keyboardDownArrow: Keysym.down,
        .keyboardLeftArrow: Keysym.left,
        .keyboardRightArrow: Keysym.right,
        .keyboardDeleteForward: Keysym.delete,
    ]
}

/// The screen in SwiftUI. Several may exist at once (inline and full
/// screen); each subscribes to the client's frames, and the one shown last
/// is the one the keyboard goes to.
struct RFBScreen: UIViewRepresentable {
    @ObservedObject var client: RFBClient
    var zoomed: Bool
    @Binding var keyboardRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RFBScreenView {
        let v = RFBScreenView(frame: .zero)
        v.client = client
        context.coordinator.sink = client.addSink { [weak v] image in v?.show(image) }
        context.coordinator.client = client
        context.coordinator.lastKeyboardRequest = keyboardRequest
        return v
    }

    func updateUIView(_ v: RFBScreenView, context: Context) {
        v.zoomed = zoomed
        if keyboardRequest != context.coordinator.lastKeyboardRequest {
            context.coordinator.lastKeyboardRequest = keyboardRequest
            if v.isFirstResponder { _ = v.resignFirstResponder() } else { _ = v.becomeFirstResponder() }
        }
    }

    static func dismantleUIView(_ v: RFBScreenView, coordinator: Coordinator) {
        if let id = coordinator.sink { coordinator.client?.removeSink(id) }
    }

    final class Coordinator {
        var sink: UUID?
        weak var client: RFBClient?
        var lastKeyboardRequest = 0
    }
}
