package dev.drengr.sdk

import android.app.Activity
import android.view.View
import android.view.Window
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Compose-present linkage + fail-open behavior of the tap-capture pieces on JVM. */
class ComposeTapCaptureTest {

    @Test
    fun installFailsOpenWhenWindowIsUnavailable() {
        // Stubbed Activity.getWindow() returns null → clean false, no throw.
        assertFalse(ComposeTapCapture.install(Activity()) {})
        assertFalse(ComposeTapCapture.uninstall(Activity()))
    }

    @Test
    fun publicApiFailsOpenWhenWindowIsUnavailable() {
        assertFalse(Drengr.experimentalComposeTapCapture(Activity()))
        assertFalse(Drengr.experimentalComposeTapCaptureStop(Activity()))
    }

    @Test
    fun resolverReturnsNullForNonComposeTree() {
        assertFalse(ComposeSemanticsResolver.resolve(View(null), 10f, 10f) != null)
    }

    @Test
    fun observerForwardsAndNeverThrowsOnNullEvent() {
        var forwarded = false
        val wrapped = java.lang.reflect.Proxy.newProxyInstance(
            Window.Callback::class.java.classLoader,
            arrayOf(Window.Callback::class.java),
        ) { _, method, _ ->
            if (method.name == "dispatchTouchEvent") { forwarded = true; true } else null
        } as Window.Callback
        val observer = WindowCallbackTapObserver(wrapped) { _, _ -> }
        assertTrue(observer.dispatchTouchEvent(null))
        assertTrue("must forward to the wrapped callback", forwarded)
    }
}
