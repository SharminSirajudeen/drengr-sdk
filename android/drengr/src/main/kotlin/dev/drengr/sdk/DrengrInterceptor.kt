package dev.drengr.sdk

import okhttp3.Interceptor
import okhttp3.MediaType
import okhttp3.Response
import okio.Buffer
import okio.ForwardingSink
import okio.Sink
import okio.buffer

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
            throw e
        }

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
            respBody = null
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
        if (body.isOneShot() || body.isDuplex()) return null
        val declared = try { body.contentLength() } catch (_: Throwable) { -1L }
        if (declared > maxBodyBytes) return null
        val buffer = Buffer()
        val capped = CappedSink(buffer, maxBodyBytes)
        val sink = capped.buffer()
        body.writeTo(sink)
        sink.flush()
        if (capped.overflowed) return null
        return buffer.readUtf8()
    }

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
        try { block() } catch (_: Throwable) {}
    }
}
