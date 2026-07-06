import Foundation
import CoreGraphics

/// Platform-neutral accessibility traits (mapped from UIAccessibilityTraits by the adapter).
struct AXTraitFlags: OptionSet {
    let rawValue: Int
    static let button     = AXTraitFlags(rawValue: 1 << 0)
    static let link       = AXTraitFlags(rawValue: 1 << 1)
    static let staticText = AXTraitFlags(rawValue: 1 << 2)
    static let textEntry  = AXTraitFlags(rawValue: 1 << 3)
    static let adjustable = AXTraitFlags(rawValue: 1 << 4)
    static let image      = AXTraitFlags(rawValue: 1 << 5)
}

/// One node of an accessibility tree (UIKit adapter in TapCapture, mocks in tests).
protocol AXNode {
    var axIsElement: Bool { get }
    var axLabel: String? { get }
    var axValue: String? { get }
    var axIdentifier: String? { get }
    /// Screen coordinates (UIKit accessibilityFrame convention).
    var axFrame: CGRect { get }
    var axTraits: AXTraitFlags { get }
    var axClassName: String { get }
    var axChildren: [AXNode] { get }
}

/// The semantic element resolved under a tap point.
struct AXHit {
    let label: String?
    let value: String?
    let identifier: String?
    let traits: AXTraitFlags
    let className: String
}

/// Bounded point-hit walk: interactive+labeled outranks labeled outranks
/// interactive-unlabeled; ties go deepest, then smallest, then topmost sibling.
enum AXTreeWalk {
    static let maxNodes = 512
    static let maxDepth = 24

    static func hit(root: AXNode, at point: CGPoint) -> AXHit? {
        var budget = maxNodes
        var best: Candidate?
        descend(root, point, 0, &budget, &best)
        return best.map {
            AXHit(label: normalized($0.node.axLabel), value: normalized($0.node.axValue),
                  identifier: normalized($0.node.axIdentifier), traits: $0.node.axTraits,
                  className: $0.node.axClassName)
        }
    }

    private struct Candidate {
        let node: AXNode
        let score: Int
        let depth: Int
        let area: CGFloat
    }

    private static func isInteractive(_ t: AXTraitFlags) -> Bool {
        !t.intersection([.button, .link, .adjustable]).isEmpty
    }

    private static func descend(_ node: AXNode, _ p: CGPoint, _ depth: Int,
                                _ budget: inout Int, _ best: inout Candidate?) {
        if budget <= 0 || depth > maxDepth { return }
        budget -= 1
        let frame = node.axFrame
        if node.axIsElement {
            guard frame.contains(p) else { return }
            let labeled = normalized(node.axIdentifier) != nil || normalized(node.axLabel) != nil
            let score = (labeled ? 2 : 0) + (isInteractive(node.axTraits) ? 1 : 0)
            guard score > 0 else { return }
            let c = Candidate(node: node, score: score, depth: depth, area: frame.width * frame.height)
            if best.map({ better(c, than: $0) }) ?? true { best = c }
            return
        }
        // Prune off-point branches; zero-frame containers (common in SwiftUI) still recurse.
        if !frame.isEmpty && !frame.contains(p) { return }
        for child in node.axChildren.reversed() {   // topmost sibling first
            descend(child, p, depth + 1, &budget, &best)
        }
    }

    private static func better(_ a: Candidate, than b: Candidate) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.depth != b.depth { return a.depth > b.depth }
        return a.area < b.area
    }

    private static func normalized(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
