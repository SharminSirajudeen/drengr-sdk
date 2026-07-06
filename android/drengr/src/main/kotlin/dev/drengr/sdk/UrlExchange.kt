package dev.drengr.sdk

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Capture state for one HttpURLConnection exchange. Emits a redacted
 * [NetworkEvent] once, at the first terminal signal (response EOF/close,
 * transport error, or disconnect). Fail-open: capture errors never surface.
 */
internal class UrlExchange(private val delegate: HttpURLConnection, private val rawUrl: String) {
    private val reqHeaders = LinkedHashMap<String, String>()
    private val emitted = AtomicBoolean(false)
    private val reqBuf = CappedBuffer(UrlConnectionCapture.maxBodyBytes)
    private val respBuf = CappedBuffer(UrlConnectionCapture.maxBodyBytes)

    @Volatile private var startMs = 0L
    @Volatile private var status = 0
    @Volatile private var reqBytes = 0L
    @Volatile private var respBytes = 0L

    fun begin() {
        if (startMs == 0L) startMs = System.currentTimeMillis()
    }

    fun noteStatus(code: Int) {
        if (code > 0) status = code
    }

    fun recordHeader(key: String?, value: String?, add: Boolean) {
        if (key == null) return
        try {
            val v = value ?: ""
            reqHeaders[key] = if (add && reqHeaders.containsKey(key)) "${reqHeaders[key]}, $v" else v
        } catch (_: Throwable) {}
    }

    fun output(real: OutputStream): OutputStream = TeeOut(real)

    fun input(real: InputStream): InputStream = TeeIn(real)

    fun errorStream(real: InputStream?): InputStream? = real?.let { TeeIn(it) }

    fun finish(error: Throwable?) {
        if (!emitted.compareAndSet(false, true)) return
        try {
            val st = status
            // Never-started exchange (e.g. disconnect before any I/O): nothing to report.
            if (error == null && st <= 0 && startMs == 0L && respBytes == 0L) return
            val respHeaders = LinkedHashMap<String, String>()
            if (st > 0) {
                try {
                    for ((k, vs) in delegate.headerFields ?: emptyMap()) {
                        if (k != null && vs != null) respHeaders[k] = vs.joinToString(", ")
                    }
                } catch (_: Throwable) {}
            }
            val reqCt = reqHeaders.entries.firstOrNull { it.key.equals("content-type", ignoreCase = true) }?.value
            val reqText = if (!reqBuf.overflowed && isTextual(reqCt)) reqBuf.text() else null
            val respCt = try { delegate.contentType } catch (_: Throwable) { null }
            val respText = if (st > 0 && !respBuf.overflowed && isTextual(respCt)) respBuf.text() else null
            val extra = UrlConnectionCapture.redactExtra
            val t0 = if (startMs > 0) startMs else System.currentTimeMillis()
            UrlConnectionCapture.emit(
                NetworkEvent(
                    method = try { delegate.requestMethod ?: "GET" } catch (_: Throwable) { "GET" },
                    url = Redact.redactUrl(rawUrl),
                    statusCode = if (st > 0) st else null,
                    durationMs = System.currentTimeMillis() - t0,
                    requestBodyBytes = reqBytes,
                    responseBodyBytes = respBytes,
                    requestHeaders = Redact.redactHeaders(reqHeaders, extra),
                    responseHeaders = Redact.redactHeaders(respHeaders, extra),
                    requestBody = reqText?.let { Redact.redactBody(it) },
                    responseBody = respText?.let { Redact.redactBody(it) },
                    errorText = if (error != null && st <= 0) error.javaClass.simpleName else null,
                    timestampMs = t0,
                ),
            )
        } catch (_: Throwable) {}
    }

    private fun isTextual(ct: String?): Boolean {
        val s = ct?.lowercase() ?: return false
        return s.startsWith("text/") || s.contains("json") || s.contains("xml") ||
            s.contains("x-www-form-urlencoded") || s.contains("graphql")
    }

    private inner class TeeOut(private val real: OutputStream) : OutputStream() {
        override fun write(b: Int) {
            real.write(b)
            try { reqBytes++; reqBuf.write(b) } catch (_: Throwable) {}
        }

        override fun write(b: ByteArray, off: Int, len: Int) {
            real.write(b, off, len)
            try { reqBytes += len; reqBuf.write(b, off, len) } catch (_: Throwable) {}
        }

        override fun flush() = real.flush()
        override fun close() = real.close()
    }

    private inner class TeeIn(private val real: InputStream) : InputStream() {
        override fun read(): Int {
            val b = try { real.read() } catch (e: Throwable) { finish(e); throw e }
            if (b < 0) finish(null) else { respBytes++; try { respBuf.write(b) } catch (_: Throwable) {} }
            return b
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            val n = try { real.read(b, off, len) } catch (e: Throwable) { finish(e); throw e }
            if (n < 0) finish(null) else { respBytes += n; try { respBuf.write(b, off, n) } catch (_: Throwable) {} }
            return n
        }

        override fun available(): Int = real.available()
        override fun skip(n: Long): Long = real.skip(n)

        override fun close() {
            try { real.close() } finally { finish(null) }
        }
    }
}

/** Buffers at most [limit] bytes; the rest is dropped and flagged as overflow. */
internal class CappedBuffer(private val limit: Long) {
    private val buf = ByteArrayOutputStream()

    var overflowed = false
        private set

    @Synchronized
    fun write(b: Int) {
        if (overflowed) return
        if (buf.size() >= limit) { overflowed = true; return }
        buf.write(b)
    }

    @Synchronized
    fun write(b: ByteArray, off: Int, len: Int) {
        if (overflowed) return
        val room = limit - buf.size()
        if (len <= room) {
            buf.write(b, off, len)
        } else {
            if (room > 0) buf.write(b, off, room.toInt())
            overflowed = true
        }
    }

    @Synchronized
    fun text(): String? = try {
        if (buf.size() == 0) null else String(buf.toByteArray(), Charsets.UTF_8)
    } catch (_: Throwable) {
        null
    }
}
