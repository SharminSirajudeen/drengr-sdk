package dev.drengr.sdk

import android.app.Activity

/**
 * Experimental Compose tap capture: wraps the activity's Window.Callback to
 * observe taps, resolves the tapped Compose node's semantics, emits a labeled
 * [TapEvent]. Labels are value-scrubbed before leaving this layer. Fail-open
 * and restore-safe (uninstall restores the original callback only while ours
 * is still on top). Loads only behind the compose class-load guard in [Drengr].
 */
internal object ComposeTapCapture {

    fun install(activity: Activity, onTap: (TapEvent) -> Unit): Boolean {
        return try {
            val window = activity.window ?: return false
            val current = window.callback ?: return false
            if (current is WindowCallbackTapObserver) return true
            val screen = activity.javaClass.name
            window.callback = WindowCallbackTapObserver(current) { x, y ->
                try {
                    val root = window.peekDecorView() ?: return@WindowCallbackTapObserver
                    val hit = ComposeSemanticsResolver.resolve(root, x, y)
                        ?: return@WindowCallbackTapObserver
                    onTap(
                        TapEvent(
                            label = Redact.scrubValues(hit.label),
                            role = hit.role,
                            source = "compose_semantics",
                            x = x,
                            y = y,
                            screen = screen,
                            timestampMs = System.currentTimeMillis(),
                        ),
                    )
                } catch (_: Throwable) {}
            }
            true
        } catch (_: Throwable) {
            false
        }
    }

    fun uninstall(activity: Activity): Boolean {
        return try {
            val window = activity.window ?: return false
            val cb = window.callback as? WindowCallbackTapObserver ?: return false
            window.callback = cb.wrapped
            true
        } catch (_: Throwable) {
            false
        }
    }
}
