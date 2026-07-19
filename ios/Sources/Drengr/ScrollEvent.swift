import Foundation

/// A captured scroll friction signal (rage or dead). Position is normalized like
/// TapEvent; `directionDown` is the intended content scroll. Mirrors the Android
/// `ScrollEvent` (dev.drengr.sdk.ScrollEvent) field-for-field.
struct ScrollEvent {
    /// true = user tried to scroll toward the bottom (reveal content below).
    let directionDown: Bool
    /// Gesture-end position NORMALIZED to 0.0–1.0 of the window.
    let x: Double
    let y: Double
    /// Current screen name at gesture time (may be "").
    let screen: String
    let timestampMs: Int64
}
