package dev.drengr.sdk

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TapDetectorTest {
    private val d = TapDetector(slopPx = 24f, maxTapMs = 500L)

    @Test
    fun downThenUpWithinSlopIsTap() {
        assertFalse(d.onMotion(TapDetector.ACTION_DOWN, 100f, 100f, 0L))
        assertTrue(d.onMotion(TapDetector.ACTION_UP, 105f, 95f, 120L))
    }

    @Test
    fun moveBeyondSlopCancelsTap() {
        d.onMotion(TapDetector.ACTION_DOWN, 100f, 100f, 0L)
        d.onMotion(TapDetector.ACTION_MOVE, 200f, 100f, 50L)
        assertFalse(d.onMotion(TapDetector.ACTION_UP, 100f, 100f, 100L))
    }

    @Test
    fun smallMoveKeepsTap() {
        d.onMotion(TapDetector.ACTION_DOWN, 100f, 100f, 0L)
        d.onMotion(TapDetector.ACTION_MOVE, 110f, 108f, 50L)
        assertTrue(d.onMotion(TapDetector.ACTION_UP, 104f, 102f, 100L))
    }

    @Test
    fun longPressIsNotTap() {
        d.onMotion(TapDetector.ACTION_DOWN, 100f, 100f, 0L)
        assertFalse(d.onMotion(TapDetector.ACTION_UP, 100f, 100f, 900L))
    }

    @Test
    fun upBeyondSlopIsNotTap() {
        d.onMotion(TapDetector.ACTION_DOWN, 100f, 100f, 0L)
        assertFalse(d.onMotion(TapDetector.ACTION_UP, 160f, 100f, 100L))
    }

    @Test
    fun cancelResetsGesture() {
        d.onMotion(TapDetector.ACTION_DOWN, 100f, 100f, 0L)
        d.onMotion(TapDetector.ACTION_CANCEL, 100f, 100f, 50L)
        assertFalse(d.onMotion(TapDetector.ACTION_UP, 100f, 100f, 100L))
    }

    @Test
    fun multiTouchIsNotTap() {
        d.onMotion(TapDetector.ACTION_DOWN, 100f, 100f, 0L)
        d.onMotion(TapDetector.ACTION_POINTER_DOWN, 300f, 300f, 20L)
        assertFalse(d.onMotion(TapDetector.ACTION_UP, 100f, 100f, 100L))
    }

    @Test
    fun upWithoutDownIsNotTap() {
        assertFalse(d.onMotion(TapDetector.ACTION_UP, 100f, 100f, 100L))
    }

    @Test
    fun secondTapAfterFirstStillDetected() {
        d.onMotion(TapDetector.ACTION_DOWN, 100f, 100f, 0L)
        assertTrue(d.onMotion(TapDetector.ACTION_UP, 100f, 100f, 100L))
        d.onMotion(TapDetector.ACTION_DOWN, 50f, 50f, 1000L)
        assertTrue(d.onMotion(TapDetector.ACTION_UP, 52f, 48f, 1100L))
    }
}
