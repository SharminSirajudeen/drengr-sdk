package dev.drengr.sdk

import android.view.MotionEvent
import android.view.Window

/**
 * Delegating Window.Callback that reports completed taps (window coordinates px)
 * and forwards every event untouched. Fail-open: observer errors never affect
 * touch delivery. [wrapped] is kept for restore.
 */
internal class WindowCallbackTapObserver(
    val wrapped: Window.Callback,
    private val onTap: (Float, Float) -> Unit,
) : Window.Callback by wrapped {

    private val detector = TapDetector()

    override fun dispatchTouchEvent(event: MotionEvent?): Boolean {
        try {
            if (event != null &&
                detector.onMotion(event.actionMasked, event.x, event.y, event.eventTime)
            ) {
                onTap(event.x, event.y)
            }
        } catch (_: Throwable) {}
        return wrapped.dispatchTouchEvent(event)
    }
}
