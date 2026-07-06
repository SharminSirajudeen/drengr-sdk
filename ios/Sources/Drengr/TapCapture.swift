#if canImport(UIKit) && !os(watchOS)
import Foundation
import UIKit
import ObjectiveC.runtime

/// EXPERIMENTAL semantic tap capture. Observes touches via a restore-safe
/// UIWindow.sendEvent swizzle (original IMP always runs FIRST — the app gets its
/// touches untouched), then resolves the tapped element's semantic label by
/// walking the accessibility tree under the tap point. SwiftUI projects its
/// Button/Text/TextField semantics into accessibility elements of the hosting
/// view, so the same walk labels UIKit and SwiftUI taps alike. Fail-open at
/// every layer: missing method → never installs; no hit → class_fallback event.
enum TapCapture {
    struct Config {
        var onEvent: (TapEvent) -> Void
        var isEnabled: () -> Bool
    }

    private static var config: Config?
    private static var installed = false
    private static var originalIMP: IMP?
    private static let lock = NSLock()

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
        guard installed, let imp = originalIMP,
              let method = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.sendEvent(_:))) else { return }
        method_setImplementation(method, imp)
        installed = false
        config = nil
    }

    private static func observe(_ window: UIWindow, _ event: UIEvent) {
        lock.lock(); let cfg = config; lock.unlock()
        guard let cfg = cfg, cfg.isEnabled(), event.type == .touches,
              let touch = event.allTouches?.first(where: { $0.phase == .ended && $0.tapCount >= 1 }),
              touch.window === window else { return }
        cfg.onEvent(resolve(window: window, point: touch.location(in: window)))
    }

    /// Main-thread only (sendEvent is). Hit-test gives the concrete fallback class;
    /// the accessibility walk gives the semantic label.
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
            tsMs: Int64(Date().timeIntervalSince1970 * 1000))
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
