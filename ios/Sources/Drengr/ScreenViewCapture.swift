#if canImport(UIKit) && !os(watchOS)
import Foundation
import UIKit
import ObjectiveC.runtime

/// screen_view autocapture via a restore-safe UIViewController.viewDidAppear(_:)
/// swizzle (original IMP always runs FIRST — the app's lifecycle is untouched).
/// Container and system controllers are skipped so only content screens count;
/// the screen name is the VC type (stable, non-PII) with a redacted title
/// fallback for bare UIKit classes. Emits `{kind: screen_view, screen,
/// prev_screen}` and maintains ScreenState for taps and crashes. Fail-open.
enum ScreenViewCapture {
    struct Config {
        var onEvent: ([String: Any]) -> Void
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
        let sel = #selector(UIViewController.viewDidAppear(_:))
        guard let method = class_getInstanceMethod(UIViewController.self, sel) else { return }
        typealias AppearIMP = @convention(c) (UIViewController, Selector, Bool) -> Void
        let imp = method_getImplementation(method)
        originalIMP = imp
        let orig = unsafeBitCast(imp, to: AppearIMP.self)
        let block: @convention(block) (UIViewController, Bool) -> Void = { vc, animated in
            orig(vc, sel, animated)
            observe(vc)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        installed = true
    }

    /// Restore the original viewDidAppear IMP.
    static func uninstall() {
        lock.lock(); defer { lock.unlock() }
        guard installed, let imp = originalIMP,
              let method = class_getInstanceMethod(UIViewController.self,
                                                   #selector(UIViewController.viewDidAppear(_:))) else { return }
        method_setImplementation(method, imp)
        installed = false
        config = nil
    }

    private static func observe(_ vc: UIViewController) {
        lock.lock(); let cfg = config; lock.unlock()
        guard let cfg = cfg else { return }
        let name = screenName(for: vc)
        // Track state even while paused (opt-out → opt-in keeps prev_screen
        // correct, matching the JS SDK); emission alone is gated.
        guard let prev = ScreenState.transition(to: name) else { return }
        CrashCapture.noteScreen(name)
        guard cfg.isEnabled() else { return }
        cfg.onEvent([
            "kind": "screen_view",
            "ts_ms": Int64(Date().timeIntervalSince1970 * 1000),
            "screen": name,
            "prev_screen": prev,
        ])
    }

    static let maxScreenChars = 256

    /// Screen name for a view controller, "" when it isn't a content screen.
    /// Priority: hosted SwiftUI root type > app VC class name > redacted title
    /// (bare UIKit classes only) > class name. Generics are stripped the same
    /// way Flutter strips them from route runtimeTypes.
    static func screenName(for vc: UIViewController) -> String {
        if vc is UINavigationController || vc is UITabBarController
            || vc is UISplitViewController || vc is UIPageViewController
            || vc is UIAlertController { return "" }
        let cls = String(describing: type(of: vc))
        if isSystemClass(cls) { return "" }
        if let hosted = hostedRootName(cls) { return clean(hosted) }
        if cls.hasPrefix("UI"), let title = redactedTitle(vc) { return title }
        return clean(String(cls.prefix(while: { $0 != "<" })))
    }

    /// UIKit-internal chrome (keyboards, input assistants, private classes)
    /// never counts as a screen.
    private static func isSystemClass(_ cls: String) -> Bool {
        cls.hasPrefix("_") || cls.hasPrefix("UIInput") || cls.hasPrefix("UIKeyboard")
            || cls.hasPrefix("UISystem") || cls.hasPrefix("UIEditing")
            || cls.hasPrefix("UIPrediction") || cls.hasPrefix("UICompatibility")
            || cls.hasPrefix("UIApplicationRotation")
    }

    /// "UIHostingController<CheckoutView>" → "CheckoutView" (the developer-named
    /// SwiftUI root — the stable, meaningful screen key). Nested generics keep
    /// their outermost type name.
    static func hostedRootName(_ cls: String) -> String? {
        guard cls.hasPrefix("UIHostingController<"), cls.hasSuffix(">") else { return nil }
        let inner = cls.dropFirst("UIHostingController<".count).dropLast()
        let name = inner.prefix(while: { $0 != "<" && $0 != "," })
        return name.isEmpty ? nil : String(name)
    }

    /// Titles are human text and can carry PII — scrub before use.
    private static func redactedTitle(_ vc: UIViewController) -> String? {
        let raw = vc.navigationItem.title ?? vc.title ?? ""
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return clean(t)
    }

    private static func clean(_ s: String) -> String {
        Redact.scrubValues(String(s.prefix(maxScreenChars)))
    }
}
#endif
