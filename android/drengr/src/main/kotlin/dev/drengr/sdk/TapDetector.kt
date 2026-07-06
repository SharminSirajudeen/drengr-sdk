package dev.drengr.sdk

import kotlin.math.abs

/** Pure tap classifier over framework motion-action codes (no android deps → JVM-testable). */
internal class TapDetector(
    private val slopPx: Float = 24f,
    private val maxTapMs: Long = 500L,
) {
    private var tracking = false
    private var downX = 0f
    private var downY = 0f
    private var downT = 0L

    /** Feed one motion sample; returns true when this sample completes a tap. */
    fun onMotion(action: Int, x: Float, y: Float, timeMs: Long): Boolean {
        when (action) {
            ACTION_DOWN -> {
                tracking = true; downX = x; downY = y; downT = timeMs
            }
            ACTION_MOVE ->
                if (tracking && (abs(x - downX) > slopPx || abs(y - downY) > slopPx)) tracking = false
            ACTION_UP -> {
                val tap = tracking && timeMs - downT <= maxTapMs &&
                    abs(x - downX) <= slopPx && abs(y - downY) <= slopPx
                tracking = false
                return tap
            }
            else -> tracking = false // CANCEL, POINTER_DOWN (multi-touch), …
        }
        return false
    }

    companion object {
        // Values match MotionEvent.ACTION_* constants.
        const val ACTION_DOWN = 0
        const val ACTION_UP = 1
        const val ACTION_MOVE = 2
        const val ACTION_CANCEL = 3
        const val ACTION_POINTER_DOWN = 5
    }
}
