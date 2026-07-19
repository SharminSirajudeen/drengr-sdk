import Foundation

/// Rage-tap burst state, folded on the main thread by TapCapture.
struct TapBurstState {
    var count = 0
    var lastMs: Int64 = 0
    var x = 0.0
    var y = 0.0
    var label = ""
    var reported = false
}

/// rage_tap / dead_tap derivation from the raw tap stream. Thresholds and burst
/// semantics match the Flutter reference (behavior.dart) exactly so a rage_tap
/// means the same thing on every platform: same burst = within 600 ms of the
/// previous tap AND within 24 pt AND the same label; a burst reports ONCE, when
/// it first reaches 3 taps. Pure — unit-tested off-device.
enum TapBehavior {
    static let rageWindowMs: Int64 = 600
    static let rageRadiusPt = 24.0
    static let rageMinTaps = 3

    /// Fold one tap into the burst. Positions are window POINTS (the 24 pt
    /// radius is physical — normalized coords would scale it with the screen).
    /// Returns the tap count to report when a burst first crosses the
    /// threshold, else nil.
    static func fold(_ s: inout TapBurstState, x: Double, y: Double,
                     label: String, tsMs: Int64) -> Int? {
        let dx = x - s.x
        let dy = y - s.y
        let sameBurst = tsMs - s.lastMs <= rageWindowMs
            && (dx * dx + dy * dy).squareRoot() <= rageRadiusPt
            && label == s.label
        if sameBurst {
            s.count += 1
        } else {
            s.count = 1
            s.reported = false
            s.label = label
        }
        s.x = x
        s.y = y
        s.lastMs = tsMs
        if s.count >= rageMinTaps && !s.reported {
            s.reported = true
            return s.count
        }
        return nil
    }

    /// Contract shape for rage_tap / dead_tap: the tap's base fields (screen,
    /// label, x, y — already redacted by TapResolve) plus `count` for rage.
    static func event(kind: String, from e: TapEvent, count: Int? = nil) -> [String: Any] {
        var o: [String: Any] = [
            "kind": kind,
            "ts_ms": e.timestampMs,
            "screen": e.screen,
            "label": e.label ?? "",
            "x": e.x,
            "y": e.y,
        ]
        if let c = count { o["count"] = c }
        return o
    }
}
