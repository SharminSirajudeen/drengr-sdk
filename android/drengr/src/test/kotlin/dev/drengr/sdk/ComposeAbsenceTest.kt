package dev.drengr.sdk

import android.app.Activity
import org.junit.Assert.assertEquals
import org.junit.Test

/** SDK loads and experimentalComposeTapCapture no-ops when androidx.compose.* is absent. */
class ComposeAbsenceTest {

    // Re-defines dev.drengr.sdk classes under a loader where androidx.compose.* throws.
    private class HidingLoader(private val app: ClassLoader) : ClassLoader(null) {
        override fun loadClass(name: String, resolve: Boolean): Class<*> {
            if (name.startsWith("androidx.compose.")) throw ClassNotFoundException(name)
            if (name.startsWith("dev.drengr.sdk.")) {
                findLoadedClass(name)?.let { return it }
                val stream = app.getResourceAsStream(name.replace('.', '/') + ".class")
                    ?: throw ClassNotFoundException(name)
                val bytes = stream.use { it.readBytes() }
                return defineClass(name, bytes, 0, bytes.size)
            }
            return app.loadClass(name)
        }
    }

    @Test
    fun tapCaptureIsCleanNoOpWithoutCompose() {
        val loader = HidingLoader(ComposeAbsenceTest::class.java.classLoader!!)
        val cls = Class.forName("dev.drengr.sdk.Drengr", true, loader)
        val instance = cls.getDeclaredField("INSTANCE").get(null)
        val m = cls.getMethod("experimentalComposeTapCapture", Activity::class.java)
        assertEquals("must no-op without compose", false, m.invoke(instance, Activity()))
    }

    @Test
    fun tapCaptureStopIsCleanNoOpWithoutCompose() {
        val loader = HidingLoader(ComposeAbsenceTest::class.java.classLoader!!)
        val cls = Class.forName("dev.drengr.sdk.Drengr", true, loader)
        val instance = cls.getDeclaredField("INSTANCE").get(null)
        val m = cls.getMethod("experimentalComposeTapCaptureStop", Activity::class.java)
        assertEquals("must no-op without compose", false, m.invoke(instance, Activity()))
    }
}
