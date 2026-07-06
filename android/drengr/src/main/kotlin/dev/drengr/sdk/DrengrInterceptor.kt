package dev.drengr.sdk

import okhttp3.Interceptor
import okhttp3.MediaType
import okhttp3.Response
import okio.Buffer
import okio.ForwardingSink
import okio.Sink
import okio.buffer

/**
 * OkHttp interceptor that captures every exchange and emits a redacted
 * [NetworkEvent]. Covers OkHttp + Retrofit (the large majority of Android apps).
 *
 * Add it as an APPLICATION interceptor (`.addInterceptor(...)`) so it sees the
 * request as the app sent it and the response after redirects/retries. The
 * response body is buffered up to [maxBodyBytes] and re-emitted, so the app's
 * own read is untouched (OkHttp bodies are one-shot; we clone via a peek).
 *
 * Fail-open: any capture error is swallowed — the interceptor always returns the
 * real response (or rethrows the real transport error) exactly as without it.
 */
class DrengrInterceptor internal constructor(
    private val maxBodyBytes: Long,
    private val redactHeaderNames: Set<String>,
    private val onEvent: (NetworkEvent) -> Unit,
    private val enabled: () -> Boolean,
    private val shouldCapture: (String) -> Boolean,
) : Interceptor {

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val url = request.url.toString()
        val capture = try { enabled() && shouldCapture(url) } catch (_: Throwable) { false }
        if (!capture) return chain.proceed(request)

        val start = System.currentTimeMillis()
        val reqHeaders = headerMap(request.headers)
        val reqBody = try { readRequestBody(request) } catch (_: Throwable) { null }

        val response: Response = try {
            chain.proceed(request)
        } catch (e: Throwable) {
            safeEmit {
                onEvent(
                    NetworkEvent(
                        method = request.method,
                        url = Redact.redactUrl(url),
                        statusCode = null,
                        durationMs = System.currentTimeMillis() - start,
                        requestBodyBytes = (reqBody?.length ?: 0).toLong(),
                        responseBodyBytes = 0,
                        requestHeaders = Redact.redactHeaders(reqHeaders, redactHeaderNames),
                        responseHeaders = emptyMap(),
                        requestBody = reqBody?.let { Redact.redactBody(it) },
                        responseBody = null,
                        errorText = e.javaClass.simpleName,
                        timestampMs = start,
                    ),
                )
            }
            throw e // the app sees exactly what it would have without capture
        }

        // Read a COPY of the body via peekBody — the app's one-shot body is never
        // consumed. Textual + within cap → captured; else size-only.
        var respBody: String? = null
        var respBytes = 0L
        try {
            val body = response.body
            if (body != null) {
                respBytes = body.contentLength().coerceAtLeast(0)
                if (isTextual(body.contentType())) {
                    val peek = response.peekBody(maxBodyBytes)
                    val text = peek.string()
                    if (text.length.toLong() <= maxBodyBytes) respBody = text
                    if (respBytes == 0L) respBytes = text.length.toLong()
                }
            }
        } catch (_: Throwable) {
            respBody = null // size-only capture on any read hiccup
        }

        val statusCode = response.code
        safeEmit {
            onEvent(
                NetworkEvent(
                    method = request.method,
                    url = Redact.redactUrl(url),
                    statusCode = statusCode,
                    durationMs = System.currentTimeMillis() - start,
                    requestBodyBytes = (reqBody?.length ?: 0).toLong(),
                    responseBodyBytes = respBytes,
                    requestHeaders = Redact.redactHeaders(reqHeaders, redactHeaderNames),
                    responseHeaders = Redact.redactHeaders(headerMap(response.headers), redactHeaderNames),
                    requestBody = reqBody?.let { Redact.redactBody(it) },
                    responseBody = respBody?.let { Redact.redactBody(it) },
                    errorText = null,
                    timestampMs = start,
                ),
            )
        }
        return response
    }

    private fun readRequestBody(request: okhttp3.Request): String? {
        val body = request.body ?: return null
        if (!isTextual(body.contentType())) return null
        // A one-shot/duplex body can be written only once; reading it here would
        // consume the app's own copy so its real request ships empty. Skip.
        if (body.isOneShot() || body.isDuplex()) return null
        // Bail BEFORE materializing when the DECLARED length already exceeds the
        // cap — a large upload must never be buffered into memory (OOM/ANR).
        val declared = try { body.contentLength() } catch (_: Throwable) { -1L }
        if (declared > maxBodyBytes) return null
        // Unknown length (-1, chunked): write through a HARD-capped sink so a
        // large/streaming body still can't buffer unbounded. Over cap → size-only.
        val buffer = Buffer()
        val capped = CappedSink(buffer, maxBodyBytes)
        val sink = capped.buffer()
        body.writeTo(sink)
        sink.flush()
        if (capped.overflowed) return null
        return buffer.readUtf8()
    }

    /** A sink that forwards at most [limit] bytes and then drops the rest, so an
     *  unbounded body can never exhaust memory. Records whether it overflowed. */
    private class CappedSink(delegate: Sink, private val limit: Long) : ForwardingSink(delegate) {
        var overflowed = false
            private set
        private var written = 0L

        override fun write(source: Buffer, byteCount: Long) {
            if (overflowed) { source.skip(byteCount); return }
            val room = limit - written
            if (byteCount <= room) {
                super.write(source, byteCount)
                written += byteCount
            } else {
                overflowed = true
                if (room > 0) super.write(source, room)
                source.skip(byteCount - room)
                written = limit
            }
        }
    }

    private fun headerMap(h: okhttp3.Headers): Map<String, String> {
        val out = LinkedHashMap<String, String>(h.size)
        for (i in 0 until h.size) out[h.name(i)] = h.value(i)
        return out
    }

    private fun isTextual(ct: MediaType?): Boolean {
        if (ct == null) return false
        val s = "${ct.type}/${ct.subtype}".lowercase()
        return s.startsWith("text/") || s.contains("json") || s.contains("xml") ||
            s.contains("x-www-form-urlencoded") || s.contains("graphql")
    }

    private inline fun safeEmit(block: () -> Unit) {
        try { block() } catch (_: Throwable) { /* capture must never break the app */ }
    }
}
