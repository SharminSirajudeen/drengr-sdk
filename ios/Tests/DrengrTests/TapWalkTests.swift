import XCTest
import CoreGraphics
@testable import Drengr

/// Mock accessibility node mirroring the shapes SwiftUI/UIKit project at runtime.
final class MockAXNode: AXNode {
    var axIsElement = false
    var axLabel: String?
    var axValue: String?
    var axIdentifier: String?
    var axFrame = CGRect.zero
    var axTraits: AXTraitFlags = []
    var axClassName = "MockContainer"
    var axChildren: [AXNode] = []

    static func element(label: String? = nil, value: String? = nil, id: String? = nil,
                        frame: CGRect, traits: AXTraitFlags = [],
                        cls: String = "MockElement") -> MockAXNode {
        let n = MockAXNode()
        n.axIsElement = true
        n.axLabel = label; n.axValue = value; n.axIdentifier = id
        n.axFrame = frame; n.axTraits = traits; n.axClassName = cls
        return n
    }

    static func container(frame: CGRect = .zero, _ children: [AXNode]) -> MockAXNode {
        let n = MockAXNode()
        n.axFrame = frame; n.axChildren = children
        return n
    }
}

final class TapWalkTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 400, height: 800)

    // --- walk ---

    func testButtonLabelResolves() {
        let btn = MockAXNode.element(label: "Add to Cart", frame: CGRect(x: 20, y: 100, width: 200, height: 44), traits: [.button])
        let root = MockAXNode.container(frame: screen, [btn])
        let hit = AXTreeWalk.hit(root: root, at: CGPoint(x: 50, y: 120))
        XCTAssertEqual(hit?.label, "Add to Cart")
        XCTAssertTrue(hit?.traits.contains(.button) ?? false)
    }

    func testIdentifierPreferredOverLabel() {
        let btn = MockAXNode.element(label: "Checkout", id: "checkout_button",
                                     frame: CGRect(x: 0, y: 0, width: 100, height: 40), traits: [.button])
        let root = MockAXNode.container(frame: screen, [btn])
        let hit = AXTreeWalk.hit(root: root, at: CGPoint(x: 10, y: 10))
        let ev = TapResolve.event(hit: hit, fallbackClass: "X", x: 0, y: 0, tsMs: 0)
        XCTAssertEqual(ev.label, "checkout_button")
        XCTAssertEqual(ev.labelSource, "identifier")
    }

    func testDeepestLabeledWins() {
        let p = CGPoint(x: 50, y: 50)
        let inner = MockAXNode.element(label: "Price", frame: CGRect(x: 40, y: 40, width: 60, height: 20))
        let row = MockAXNode.element(label: "Item, detail", frame: CGRect(x: 0, y: 0, width: 400, height: 80))
        let root = MockAXNode.container(frame: screen, [row, MockAXNode.container(frame: screen, [MockAXNode.container([inner])])])
        XCTAssertEqual(AXTreeWalk.hit(root: root, at: p)?.label, "Price")
    }

    func testInteractiveOutranksStaticAtSameDepth() {
        let p = CGPoint(x: 50, y: 50)
        let text = MockAXNode.element(label: "Hello", frame: CGRect(x: 0, y: 0, width: 200, height: 100), traits: [.staticText])
        let btn = MockAXNode.element(label: "Go", frame: CGRect(x: 0, y: 0, width: 200, height: 100), traits: [.button])
        let root = MockAXNode.container(frame: screen, [btn, text])
        XCTAssertEqual(AXTreeWalk.hit(root: root, at: p)?.label, "Go")
    }

    func testTopmostSiblingWinsTie() {
        let f = CGRect(x: 0, y: 0, width: 100, height: 100)
        let under = MockAXNode.element(label: "Under", frame: f, traits: [.staticText])
        let over = MockAXNode.element(label: "Over", frame: f, traits: [.staticText])
        let root = MockAXNode.container(frame: screen, [under, over])   // subview order = back-to-front
        XCTAssertEqual(AXTreeWalk.hit(root: root, at: CGPoint(x: 50, y: 50))?.label, "Over")
    }

    func testIconOnlyButtonYieldsUnlabeledInteractiveHit() {
        let icon = MockAXNode.element(frame: CGRect(x: 0, y: 0, width: 44, height: 44),
                                      traits: [.button], cls: "SwiftUI.AccessibilityNode")
        let root = MockAXNode.container(frame: screen, [icon])
        let hit = AXTreeWalk.hit(root: root, at: CGPoint(x: 10, y: 10))
        XCTAssertNotNil(hit)
        XCTAssertNil(hit?.label)
        let ev = TapResolve.event(hit: hit, fallbackClass: "X", x: 0, y: 0, tsMs: 0)
        XCTAssertEqual(ev.labelSource, "class_fallback")
        XCTAssertEqual(ev.role, "button")
        XCTAssertEqual(ev.elementClass, "SwiftUI.AccessibilityNode")
    }

    func testMissReturnsNil() {
        let btn = MockAXNode.element(label: "A", frame: CGRect(x: 0, y: 0, width: 10, height: 10), traits: [.button])
        let root = MockAXNode.container(frame: screen, [btn])
        XCTAssertNil(AXTreeWalk.hit(root: root, at: CGPoint(x: 300, y: 700)))
    }

    func testZeroFrameContainerStillRecurses() {
        let btn = MockAXNode.element(label: "Deep", frame: CGRect(x: 0, y: 0, width: 50, height: 50), traits: [.button])
        let root = MockAXNode.container([MockAXNode.container([btn])])   // .zero frames
        XCTAssertEqual(AXTreeWalk.hit(root: root, at: CGPoint(x: 5, y: 5))?.label, "Deep")
    }

    func testOffPointBranchesArePruned() {
        let far = CGRect(x: 300, y: 700, width: 50, height: 50)
        let bigSubtree = MockAXNode.container(frame: far, (0..<1000).map { _ in
            MockAXNode.element(label: "noise", frame: far)
        })
        let target = MockAXNode.element(label: "Target", frame: CGRect(x: 0, y: 0, width: 50, height: 50), traits: [.button])
        let root = MockAXNode.container(frame: screen, [target, bigSubtree])
        XCTAssertEqual(AXTreeWalk.hit(root: root, at: CGPoint(x: 5, y: 5))?.label, "Target")
    }

    func testNodeBudgetBoundsPathologicalTrees() {
        // 600 zero-frame containers each burn budget before the target is reachable.
        var children: [AXNode] = (0..<600).map { _ in MockAXNode.container([]) }
        children.insert(MockAXNode.element(label: "Late", frame: CGRect(x: 0, y: 0, width: 50, height: 50), traits: [.button]), at: 0)
        let root = MockAXNode.container(frame: screen, children)   // reversed: containers first
        XCTAssertNil(AXTreeWalk.hit(root: root, at: CGPoint(x: 5, y: 5)))
    }

    // --- resolve policy ---

    func testNilHitFallsBackToHitTestClass() {
        let ev = TapResolve.event(hit: nil, fallbackClass: "SwiftUI.PlatformViewHost", x: 0.5, y: 0.5, tsMs: 1)
        XCTAssertNil(ev.label)
        XCTAssertEqual(ev.labelSource, "class_fallback")
        XCTAssertEqual(ev.role, "view")
        XCTAssertEqual(ev.elementClass, "SwiftUI.PlatformViewHost")
    }

    func testRoleMapping() {
        XCTAssertEqual(TapResolve.role([.button]), "button")
        XCTAssertEqual(TapResolve.role([.textEntry, .button]), "text_input")
        XCTAssertEqual(TapResolve.role([.link]), "link")
        XCTAssertEqual(TapResolve.role([.staticText]), "text")
        XCTAssertEqual(TapResolve.role([]), "view")
    }

    func testLabelIsScrubbed() {
        XCTAssertEqual(TapResolve.safeLabel("Signed in as a@b.com"), "Signed in as [REDACTED-EMAIL]")
        XCTAssertEqual(TapResolve.safeLabel("   "), nil)
        XCTAssertEqual(TapResolve.safeLabel(String(repeating: "x", count: 500))?.count, TapResolve.maxLabelChars)
    }

    func testValueDroppedForTextEntry() {
        XCTAssertNil(TapResolve.safeValue("typed secret", label: "Notes", traits: [.textEntry]))
    }

    func testValueDroppedUnderSensitiveLabel() {
        XCTAssertNil(TapResolve.safeValue("a@b.com", label: "Email", traits: []))
        XCTAssertNil(TapResolve.safeValue("4111", label: "Card number", traits: [.button]))
    }

    func testValueDroppedWholeOnScrubMatch() {
        XCTAssertNil(TapResolve.safeValue("call +1 415-555-1234 now", label: "Info", traits: []))
    }

    func testBenignValueKept() {
        XCTAssertEqual(TapResolve.safeValue("2 items", label: "Cart", traits: [.button]), "2 items")
        XCTAssertEqual(TapResolve.safeValue("1", label: "Dark mode", traits: [.button]), "1")
    }
}
