import Foundation

/// A single semantically-resolved tap (already redacted by the capture layer).
public struct TapEvent {
    public let label: String?
    public let labelSource: String   // identifier | accessibility_label | class_fallback
    public let value: String?
    public let role: String          // button | link | text_input | adjustable | image | text | view
    public let elementClass: String
    /// Screen the tap landed on (maintained by screen_view capture; may be "").
    public let screen: String
    /// Whether anything on the hit path handles taps (false → dead_tap).
    public let interactive: Bool
    /// Normalized 0–1 within the window.
    public let x: Double
    public let y: Double
    public let timestampMs: Int64
}

/// Turns an accessibility hit into a redacted TapEvent (pure — unit-tested off-device).
enum TapResolve {
    static let maxLabelChars = 256
    static let maxValueChars = 128

    static let interactiveTraits: AXTraitFlags = [.button, .link, .adjustable, .textEntry]

    static func event(hit: AXHit?, fallbackClass: String, x: Double, y: Double, tsMs: Int64,
                      screen: String = "", pathInteractive: Bool = false) -> TapEvent {
        guard let h = hit else {
            return TapEvent(label: nil, labelSource: "class_fallback", value: nil, role: "view",
                            elementClass: fallbackClass, screen: screen,
                            interactive: pathInteractive, x: x, y: y, timestampMs: tsMs)
        }
        let ident = h.identifier.flatMap { safeLabel($0) }
        let lbl = h.label.flatMap { safeLabel($0) }
        let source = ident != nil ? "identifier" : (lbl != nil ? "accessibility_label" : "class_fallback")
        return TapEvent(label: ident ?? lbl, labelSource: source,
                        value: safeValue(h.value, label: h.label, traits: h.traits),
                        role: role(h.traits), elementClass: h.className, screen: screen,
                        interactive: pathInteractive || !h.traits.intersection(interactiveTraits).isEmpty,
                        x: x, y: y, timestampMs: tsMs)
    }

    static func role(_ t: AXTraitFlags) -> String {
        if t.contains(.textEntry) { return "text_input" }
        if t.contains(.button) { return "button" }
        if t.contains(.link) { return "link" }
        if t.contains(.adjustable) { return "adjustable" }
        if t.contains(.image) { return "image" }
        if t.contains(.staticText) { return "text" }
        return "view"
    }

    static func safeLabel(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return Redact.scrubValues(String(t.prefix(maxLabelChars)))
    }

    /// Values are user content: dropped for text entry, dropped under a sensitive
    /// label, dropped whole if the scrubber matched anything, else capped.
    static func safeValue(_ v: String?, label: String?, traits: AXTraitFlags) -> String? {
        guard let t = v?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if traits.contains(.textEntry) { return nil }
        if let l = label, Redact.isSensitiveName(l) { return nil }
        let capped = String(t.prefix(maxValueChars))
        let scrubbed = Redact.scrubValues(capped)
        return scrubbed == capped ? scrubbed : nil
    }
}
