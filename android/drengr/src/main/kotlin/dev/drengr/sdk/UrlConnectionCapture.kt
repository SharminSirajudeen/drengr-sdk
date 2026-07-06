package dev.drengr.sdk

import java.net.HttpURLConnection
import java.net.Proxy
import java.net.URL
import java.net.URLConnection
import java.net.URLStreamHandler
import java.net.URLStreamHandlerFactory
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.HttpsURLConnection

/**
 * Opt-in HttpURLConnection capture: a process-global delegating stream-handler
 * factory. Probe URLs created BEFORE install pin the platform-default handlers;
 * `URL(context, spec)` inherits the context's handler when protocols match, so
 * delegation needs no reflection. Fail-open everywhere: if another factory owns
 * the process, install warns once and returns false — never crashes.
 */
internal object UrlConnectionCapture {
    private val installed = AtomicBoolean(false)
    private val warned = AtomicBoolean(false)

    @Volatile private var onEvent: ((NetworkEvent) -> Unit)? = null
    @Volatile private var enabledFn: () -> Boolean = { false }

    @Volatile
    var redactExtra: Set<String> = emptySet()
        private set

    @Volatile
    var maxBodyBytes: Long = 64 * 1024
        private set

    /** Rebind sinks/config without touching the global factory (also used by tests). */
    fun bind(
        onEvent: (NetworkEvent) -> Unit,
        enabled: () -> Boolean,
        redactExtra: Set<String>,
        maxBodyBytes: Long,
    ) {
        this.onEvent = onEvent
        this.enabledFn = enabled
        this.redactExtra = redactExtra
        this.maxBodyBytes = maxBodyBytes
    }

    fun install(
        onEvent: (NetworkEvent) -> Unit,
        enabled: () -> Boolean,
        redactExtra: Set<String>,
        maxBodyBytes: Long,
    ): Boolean {
        bind(onEvent, enabled, redactExtra, maxBodyBytes)
        if (installed.get()) return true
        return try {
            val httpProbe = URL("http://drengr.invalid/")
            val httpsProbe = URL("https://drengr.invalid/")
            URL.setURLStreamHandlerFactory(DelegatingFactory(httpProbe, httpsProbe))
            installed.set(true)
            true
        } catch (_: Throwable) {
            if (warned.compareAndSet(false, true)) {
                try {
                    android.util.Log.w("Drengr", "URLStreamHandlerFactory already set; HttpURLConnection capture disabled")
                } catch (_: Throwable) {}
            }
            false
        }
    }

    fun emit(e: NetworkEvent) {
        try { if (enabledFn()) onEvent?.invoke(e) } catch (_: Throwable) {}
    }

    private class DelegatingFactory(
        private val httpProbe: URL,
        private val httpsProbe: URL,
    ) : URLStreamHandlerFactory {
        override fun createURLStreamHandler(protocol: String?): URLStreamHandler? = when (protocol) {
            "http" -> CapturingHandler(httpProbe, 80)
            "https" -> CapturingHandler(httpsProbe, 443)
            else -> null
        }
    }
}

/** Delegates to the pinned default handler and wraps http(s) connections for capture. */
internal class CapturingHandler(private val probe: URL, private val port: Int) : URLStreamHandler() {

    public override fun openConnection(u: URL): URLConnection = wrap(delegate(u).openConnection(), u)

    public override fun openConnection(u: URL, proxy: Proxy): URLConnection =
        wrap(delegate(u).openConnection(proxy), u)

    override fun getDefaultPort(): Int = port

    private fun delegate(u: URL): URL = URL(probe, u.toExternalForm())

    private fun wrap(real: URLConnection, u: URL): URLConnection = try {
        when {
            real is DrengrHttpURLConnection || real is DrengrHttpsURLConnection -> real
            real is HttpsURLConnection -> DrengrHttpsURLConnection(u, real)
            real is HttpURLConnection -> DrengrHttpURLConnection(u, real)
            else -> real
        }
    } catch (_: Throwable) {
        real
    }
}
