#if os(iOS) && canImport(SwiftUI)
import XCTest
import SwiftUI
import UIKit
@testable import Drengr

/// Real-UIKit fixture around a UIHostingController. Runs under `xcodebuild test`
/// on an iOS simulator. Label-projection cases self-skip in HEADLESS runners
/// (no window scene → the accessibility bridge never loads, so even a system
/// UIButton reports no label there); they activate automatically once this suite
/// runs inside a test-host app. Swizzle + fail-open cases run everywhere.
@available(iOS 15.0, *)
final class SwiftUIHostingFixtureTests: XCTestCase {
    private struct Fixture: View {
        var body: some View {
            VStack(spacing: 24) {
                Text("Order Summary")
                Button("Add to Cart") {}
                Button(action: {}) { Image(systemName: "heart") }
                TextField("Email", text: .constant("user@example.com"))
                List {
                    HStack { Text("Latte"); Spacer(); Text("$4.50") }
                    HStack { Text("Mocha"); Spacer(); Text("$5.00") }
                }.frame(height: 200)
            }
        }
    }

    private var window: UIWindow!

    /// The AX bridge only loads in a hosted app process; probe it empirically.
    private static let axBridgeActive: Bool = {
        let probe = UIButton(type: .system)
        probe.setTitle("probe", for: .normal)
        return probe.accessibilityLabel != nil
    }()

    override func setUp() {
        super.setUp()
        window = UIWindow(frame: UIScreen.main.bounds)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            window.windowScene = scene
        }
        window.rootViewController = UIHostingController(rootView: Fixture())
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        super.tearDown()
    }

    /// Screen-coord frame of the first element whose label contains `label`.
    private func frame(containing label: String) -> CGRect? {
        func scan(_ node: AXNode, _ depth: Int) -> CGRect? {
            if depth > 32 { return nil }
            if node.axIsElement, node.axLabel?.contains(label) == true { return node.axFrame }
            for c in node.axChildren {
                if let f = scan(c, depth + 1) { return f }
            }
            return nil
        }
        return scan(UIKitAXNode(window as NSObject), 0)
    }

    private func resolveTap(on label: String) throws -> TapEvent {
        try XCTSkipUnless(Self.axBridgeActive, "headless runner: AX bridge inert — needs a test-host app")
        let f = try XCTUnwrap(frame(containing: label), "no element projected for \(label)")
        let p = window.convert(CGPoint(x: f.midX, y: f.midY), from: nil as UIWindow?)
        return TapCapture.resolve(window: window, point: p)
    }

    func testButtonProjectsLabel() throws {
        let ev = try resolveTap(on: "Add to Cart")
        XCTAssertEqual(ev.label, "Add to Cart")
        XCTAssertEqual(ev.labelSource, "accessibility_label")
        XCTAssertEqual(ev.role, "button")
    }

    func testTextProjectsLabel() throws {
        let ev = try resolveTap(on: "Order Summary")
        XCTAssertEqual(ev.label, "Order Summary")
        XCTAssertEqual(ev.labelSource, "accessibility_label")
    }

    func testTextFieldValueNeverEmitted() throws {
        let ev = try resolveTap(on: "Email")
        XCTAssertNil(ev.value)
        XCTAssertFalse((ev.label ?? "").contains("user@example.com"))
    }

    func testListRowProjectsCombinedLabel() throws {
        let ev = try resolveTap(on: "Latte")
        XCTAssertTrue((ev.label ?? "").contains("Latte"))
        XCTAssertEqual(ev.labelSource, "accessibility_label")
    }

    /// Fail-open floor: resolve on an arbitrary point must always return an event
    /// with a concrete class, never crash — headless or hosted.
    func testResolveNeverCrashesAndCarriesClass() {
        let ev = TapCapture.resolve(window: window, point: CGPoint(x: window.bounds.midX, y: 120))
        XCTAssertFalse(ev.elementClass.isEmpty)
        XCTAssertEqual(ev.labelSource, Self.axBridgeActive ? ev.labelSource : "class_fallback")
    }

    func testSwizzleInstallsAndRestores() {
        let sel = #selector(UIWindow.sendEvent(_:))
        let before = method_getImplementation(class_getInstanceMethod(UIWindow.self, sel)!)
        TapCapture.install(config: TapCapture.Config(onEvent: { _ in }, isEnabled: { true }))
        let during = method_getImplementation(class_getInstanceMethod(UIWindow.self, sel)!)
        XCTAssertNotEqual(before, during)
        TapCapture.uninstall()
        let after = method_getImplementation(class_getInstanceMethod(UIWindow.self, sel)!)
        XCTAssertEqual(before, after)
    }
}
#endif
