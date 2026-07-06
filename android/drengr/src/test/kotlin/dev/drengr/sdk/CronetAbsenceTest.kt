package dev.drengr.sdk

import org.junit.Assert.assertNull
import org.junit.Test
import java.util.concurrent.Executor

/** SDK loads and cronetListener() no-ops when org.chromium.* is absent at runtime. */
class CronetAbsenceTest {

    // Re-defines dev.drengr.sdk classes under a loader where org.chromium.* throws.
    private class HidingLoader(private val app: ClassLoader) : ClassLoader(null) {
        override fun loadClass(name: String, resolve: Boolean): Class<*> {
            if (name.startsWith("org.chromium.")) throw ClassNotFoundException(name)
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
    fun cronetListenerIsCleanNoOpWithoutCronet() {
        val loader = HidingLoader(CronetAbsenceTest::class.java.classLoader!!)
        val cls = Class.forName("dev.drengr.sdk.Drengr", true, loader)
        val instance = cls.getDeclaredField("INSTANCE").get(null)
        val m = cls.getMethod("cronetListener", Executor::class.java)
        val result = m.invoke(instance, Executor { it.run() })
        assertNull("must no-op without Cronet", result)
    }
}
