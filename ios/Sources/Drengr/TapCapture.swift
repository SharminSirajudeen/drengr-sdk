#if canImport(UIKit) && !os(watchOS)
import Foundation
import UIKit
import ObjectiveC.runtime

/// Semantic tap capture (SwiftUI + UIKit). Observes touches via a restore-safe
/// UIWindow.sendEvent swizzle (original IMP always runs FIRST — the app gets its
/// touches untouched), then resolves the tapped element's semantic label by
/// walking the accessibility tree under the tap point. SwiftUI projects its
/// Button/Text/TextField semantics into accessibility elements of the hosting
/// view, so the same walk labels UIKit and SwiftUI taps alike. Each tap also
/// feeds the rage/dead-tap derivation (TapBehavior — Flutter-parity thresholds).
/// Fail-open at every layer: missing method → never installs; no hit →
/// class_fallback event.
enum TapCapture {
    struct Config {
        var onEvent: (TapEvent) -> Void
        /// Derived rage_tap / dead_tap events (contract-shaped dicts).
        var onBehavior: ([String: Any]) -> Void = { _ in }
        var isEnabled: () -> Bool
    }

    private static var config: Config?
    private static var installed = false
    private static var originalIMP: IMP?
    private static let lock = NSLock()
    private static var burst = TapBurstState()          // main-thread only (sendEvent is)
    private static var scrollDetector = ScrollDetector() // main-thread only
    private static var scrollBurst = ScrollBurstState()  // main-thread only

    /// Idempotent; re-install just swaps the config.
    static func install(config newConfig: Config) {
        lock.lock(); defer { lock.unlock() }
        config = newConfig
        if installed { return }
        let sel = #selector(UIWindow.sendEvent(_:))
        guard let method = class_getInstanceMethod(UIWindow.self, sel) else { return }
        typealias SendIMP = @convention(c) (UIWindow, Selector, UIEvent) -> Void
        let imp = method_getImplementation(method)
        originalIMP = imp
        let orig = unsafeBitCast(imp, to: SendIMP.self)
        let block: @convention(block) (UIWindow, UIEvent) -> Void = { window, event in
            orig(window, sel, event)
            observe(window, event)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        installed = true
    }

    /// Restore the original sendEvent IMP.
    static func uninstall() {
        lock.lock(); defer { lock.unlock() }
        burst = TapBurstState()
        scrollDetector = ScrollDetector()
        scrollBurst = ScrollBurstState()
        guard installed, let imp = originalIMP,
              let method = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.sendEvent(_:))) else { return }
        method_setImplementation(method, imp)
        installed = false
        config = nil
    }

    private static func observe(_ window: UIWindow, _ event: UIEvent) {
        lock.lock(); let cfg = config; lock.unlock()
        guard let cfg = cfg, cfg.isEnabled(), event.type == .touches,
              let touches = event.allTouches, !touches.isEmpty else { return }
        observeScroll(window, touches, cfg)   // net-travel scroll gesture (rage/dead)
        observeTap(window, touches, cfg)      // completed tap (dead/rage)
    }

    private static func observeTap(_ window: UIWindow, _ touches: Set<UITouch>, _ cfg: Config) {
        guard let touch = touches.first(where: { $0.phase == .ended && $0.tapCount >= 1 }),
              touch.window === window else { return }
        let point = touch.location(in: window)
        let tap = resolve(window: window, point: point)
        cfg.onEvent(tap)
        if !tap.interactive {
            cfg.onBehavior(TapBehavior.event(kind: "dead_tap", from: tap))
        }
        if let count = TapBehavior.fold(&burst, x: Double(point.x), y: Double(point.y),
                                        label: tap.label ?? "", tsMs: tap.timestampMs) {
            cfg.onBehavior(TapBehavior.event(kind: "rage_tap", from: tap, count: count))
        }
    }

    /// Single-finger net-travel scroll gesture → rage_scroll (frantic bursts) and
    /// dead_scroll (nothing on the hit path could scroll). Mirrors Android
    /// ScrollDetector + RageScrollDetector + ViewTapResolver.deadScroll. Only emits
    /// when the gesture is dead or a rage burst crossed — exactly like Android.
    private static func observeScroll(_ window: UIWindow, _ touches: Set<UITouch>, _ cfg: Config) {
        // Multi-touch (pinch/zoom/two-finger pan) is not a single scroll — reset the
        // tracker, mirroring Android's ScrollDetector CANCEL on a multi-pointer down.
        if touches.count > 1 {
            _ = scrollDetector.onMotion(ScrollDetector.actionCancel, y: 0)
            return
        }
        guard let touch = touches.first, touch.window === window else { return }
        let point = touch.location(in: window)
        let action: Int
        switch touch.phase {
        case .began: action = ScrollDetector.actionDown
        case .moved: action = ScrollDetector.actionMove
        case .ended: action = ScrollDetector.actionUp
        default: action = ScrollDetector.actionCancel   // .cancelled / .stationary / regionEntered…
        }
        let dir = scrollDetector.onMotion(action, y: Double(point.y))
        guard dir != 0 else { return }

        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let b = window.bounds
        let scroll = ScrollEvent(
            directionDown: dir > 0,
            x: b.width > 0 ? Double(point.x / b.width) : 0,
            y: b.height > 0 ? Double(point.y / b.height) : 0,
            screen: ScreenState.screen,
            timestampMs: ts)
        let dead = deadScroll(window: window, at: point, dir: dir)
        let burstCount = ScrollBehavior.fold(&scrollBurst, tsMs: ts)
        if dead { cfg.onBehavior(ScrollBehavior.event(kind: "dead_scroll", from: scroll)) }
        if let c = burstCount { cfg.onBehavior(ScrollBehavior.event(kind: "rage_scroll", from: scroll, count: c)) }
    }

    /// dead_scroll gate (Android parity — ViewTapResolver.deadScroll): the hit path
    /// is non-empty AND no UIScrollView on it can still scroll in `dir` (+1 =
    /// reveal-below, -1 = reveal-above). A REAL determination from live
    /// contentOffset/contentSize — never a guess. Fail-open: a nil hit test → false,
    /// so a dead_scroll is never fabricated.
    static func deadScroll(window: UIWindow, at point: CGPoint, dir: Int) -> Bool {
        deadScroll(hitView: window.hitTest(point, with: nil), dir: dir)
    }

    static func deadScroll(hitView: UIView?, dir: Int, maxHops: Int = 32) -> Bool {
        guard let start = hitView else { return false }
        var v: UIView? = start
        var hops = 0
        while let cur = v, hops < maxHops {
            if let sv = cur as? UIScrollView, scrollViewCanScroll(sv, dir: dir) { return false }
            if cur is UIWindow { break }
            v = cur.superview
            hops += 1
        }
        return true   // non-empty path, nothing on it can scroll in dir → dead
    }

    static func scrollViewCanScroll(_ sv: UIScrollView, dir: Int) -> Bool {
        guard sv.isScrollEnabled else { return false }
        let inset = sv.adjustedContentInset
        return ScrollBehavior.canScroll(
            offsetY: Double(sv.contentOffset.y),
            contentHeight: Double(sv.contentSize.height),
            boundsHeight: Double(sv.bounds.height),
            insetTop: Double(inset.top),
            insetBottom: Double(inset.bottom),
            dir: dir)
    }

    /// Main-thread only (sendEvent is). Hit-test gives the concrete fallback class
    /// and the tap-handler check; the accessibility walk gives the semantic label.
    static func resolve(window: UIWindow, point: CGPoint) -> TapEvent {
        let screenPoint = window.convert(point, to: nil as UIWindow?)
        let hitView = window.hitTest(point, with: nil)
        let hit = AXTreeWalk.hit(root: UIKitAXNode(window), at: screenPoint)
        let b = window.bounds
        return TapResolve.event(
            hit: hit,
            fallbackClass: hitView.map { NSStringFromClass(type(of: $0)) } ?? "UIWindow",
            x: b.width > 0 ? Double(point.x / b.width) : 0,
            y: b.height > 0 ? Double(point.y / b.height) : 0,
            tsMs: Int64(Date().timeIntervalSince1970 * 1000),
            screen: ScreenState.screen,
            pathInteractive: hitPathHandlesTaps(hitView))
    }

    /// Flutter-parity interactivity: anything on the hit path that handles taps
    /// (control, text editor, selectable cell, tap recognizer) makes the tap
    /// non-dead. Bounded ancestor walk; SwiftUI controls are covered by the
    /// accessibility traits instead (Button projects .button).
    static func hitPathHandlesTaps(_ view: UIView?, maxHops: Int = 24) -> Bool {
        var v = view
        var hops = 0
        while let cur = v, hops < maxHops {
            if cur is UIControl || cur is UITextView
                || cur is UITableViewCell || cur is UICollectionViewCell { return true }
            if cur.gestureRecognizers?.contains(where: { $0 is UITapGestureRecognizer && $0.isEnabled }) == true {
                return true
            }
            if cur is UIWindow { return false }
            v = cur.superview
            hops += 1
        }
        return false
    }
}

/// AXNode adapter over UIKit's NSObject accessibility protocol. SwiftUI hosting
/// views expose their scene as accessibilityElements; plain views recurse subviews.
struct UIKitAXNode: AXNode {
    let obj: NSObject
    init(_ obj: NSObject) { self.obj = obj }

    var axIsElement: Bool { obj.isAccessibilityElement }
    var axLabel: String? { obj.accessibilityLabel }
    var axValue: String? { obj.accessibilityValue }
    var axIdentifier: String? { (obj as? UIAccessibilityIdentification)?.accessibilityIdentifier }
    var axFrame: CGRect { obj.accessibilityFrame }
    var axClassName: String { NSStringFromClass(type(of: obj)) }

    var axTraits: AXTraitFlags {
        let t = obj.accessibilityTraits
        var f: AXTraitFlags = []
        if t.contains(.button) { f.insert(.button) }
        if t.contains(.link) { f.insert(.link) }
        if t.contains(.staticText) { f.insert(.staticText) }
        if t.contains(.adjustable) { f.insert(.adjustable) }
        if t.contains(.image) { f.insert(.image) }
        if t.contains(.searchField) { f.insert(.textEntry) }
        if obj is UITextField || obj is UITextView {
            f.insert(.textEntry)
        } else if obj is UIControl {
            f.insert(.button)
        }
        return f
    }

    var axChildren: [AXNode] {
        if obj.isAccessibilityElement { return [] }
        if let els = obj.accessibilityElements {
            return els.compactMap { $0 as? NSObject }.map { UIKitAXNode($0) }
        }
        if let view = obj as? UIView {
            return view.subviews.filter { !$0.isHidden && $0.alpha > 0.01 }.map { UIKitAXNode($0) }
        }
        return []
    }
}
#endif
