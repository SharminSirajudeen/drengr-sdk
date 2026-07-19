import Foundation

/// Current screen name shared by every behavior producer: screen_view maintains
/// it, taps and crashes snapshot it. Tracked even while capture is paused so
/// screen/prev_screen stay correct across an opt-out → opt-in (emission alone
/// is gated, matching the JS SDK). Thread-safe; never throws.
enum ScreenState {
    private static let lock = NSLock()
    private static var current = ""

    static var screen: String {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// Adopt `name` as the current screen. Returns the screen being left when
    /// this is a real transition, nil when `name` is empty or unchanged (no
    /// screen_view to emit).
    static func transition(to name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if name.isEmpty || name == current { return nil }
        let prev = current
        current = name
        return prev
    }

    static func reset() {
        lock.lock(); current = ""; lock.unlock()
    }
}
