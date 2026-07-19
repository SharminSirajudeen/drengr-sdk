import Foundation

/// Pure scroll-gesture classifier over touch-phase action codes (no UIKit → unit-
/// testable, exactly like Android's `ScrollDetector`). A gesture is a scroll when
/// net vertical travel exceeds `minTravelPt`; small travel (taps) is rejected, so
/// scroll and tap are mutually exclusive. Returns the intended content-scroll
/// direction when the gesture completes.
struct ScrollDetector {
    // Action codes mirror Android's MotionEvent.ACTION_* mapping so the classifier
    // reads identically on both platforms; TapCapture maps UITouch.Phase onto these.
    static let actionDown = 0
    static let actionUp = 1
    static let actionMove = 2
    static let actionCancel = 3

    // ~2× the iOS system pan slop (~10 pt) — a deliberate drag registers while a
    // jittery tap does not. This is the point-space equivalent of Android's 48 px
    // default (≈16–24 pt physical on typical 2–3× displays).
    var minTravelPt: Double = 24
    private var tracking = false
    private var downY: Double = 0

    /// Feed one motion sample; returns +1 (content-down: finger moved up) or
    /// -1 (content-up: finger moved down) when this sample completes a scroll,
    /// or 0 when the gesture is not a scroll. Net travel is measured at UP.
    mutating func onMotion(_ action: Int, y: Double) -> Int {
        switch action {
        case Self.actionDown:
            tracking = true; downY = y
        case Self.actionUp:
            let net = tracking ? y - downY : 0
            tracking = false
            return abs(net) >= minTravelPt ? (net < 0 ? 1 : -1) : 0
        case Self.actionMove:
            break   // net is measured at UP
        default:
            tracking = false   // cancel / multi-touch
        }
        return 0
    }
}

/// Rage-scroll burst state, folded on the main thread by TapCapture.
struct ScrollBurstState {
    var count = 0
    var lastMs: Int64 = 0
    var reported = false
}

/// rage_scroll / dead_scroll derivation from the completed-scroll stream. Thresholds
/// and burst semantics match the Android reference (`RageScrollDetector`,
/// `ViewTapResolver.deadScroll`) exactly so a rage_scroll means the same thing on
/// every platform: ≥4 scroll gestures each within 1200 ms of the previous = one
/// frantic burst, reported ONCE. Pure — unit-tested off-device.
enum ScrollBehavior {
    static let rageWindowMs: Int64 = 1200
    static let rageMinScrolls = 4

    /// Fold one completed scroll into the burst; returns the burst count to report
    /// as rage_scroll when it first crosses the threshold, else nil.
    static func fold(_ s: inout ScrollBurstState, tsMs: Int64) -> Int? {
        if tsMs - s.lastMs <= rageWindowMs {
            s.count += 1
        } else {
            s.count = 1
            s.reported = false
        }
        s.lastMs = tsMs
        if s.count >= rageMinScrolls && !s.reported {
            s.reported = true
            return s.count
        }
        return nil
    }

    /// Whether a scroll view with this geometry can still scroll in `dir`
    /// (+1 = reveal content below, -1 = reveal content above) — the iOS analog of
    /// Android's `View.canScrollVertically(dir)`, derived from live
    /// contentOffset/contentSize/bounds. Pure — unit-tested off-device.
    static func canScroll(offsetY: Double, contentHeight: Double, boundsHeight: Double,
                          insetTop: Double, insetBottom: Double, dir: Int) -> Bool {
        if dir > 0 {
            let maxY = contentHeight - boundsHeight + insetBottom
            return offsetY < maxY - 0.5
        }
        let minY = -insetTop
        return offsetY > minY + 0.5
    }

    /// Contract shape for rage_scroll / dead_scroll: direction + normalized pos +
    /// screen, plus `count` for rage. Mirrors Android `IngestSink.toScroll`.
    static func event(kind: String, from e: ScrollEvent, count: Int? = nil) -> [String: Any] {
        var o: [String: Any] = [
            "kind": kind,
            "ts_ms": e.timestampMs,
            "direction": e.directionDown ? "down" : "up",
            "x": e.x,
            "y": e.y,
            "screen": e.screen,
        ]
        if let c = count { o["count"] = c }
        return o
    }
}
