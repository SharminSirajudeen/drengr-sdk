package dev.drengr.sdk

import org.chromium.net.CronetException
import org.chromium.net.RequestFinishedInfo
import org.chromium.net.UrlResponseInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date
import java.util.concurrent.Executor

/** Adapter mapping tested against the cronet api-jar types (no Cronet runtime). */
class CronetAdapterTest {

    private class FakeMetrics : RequestFinishedInfo.Metrics() {
        override fun getRequestStart(): Date? = Date(1720000000000L)
        override fun getRequestEnd(): Date? = null
        override fun getDnsStart(): Date? = null
        override fun getDnsEnd(): Date? = null
        override fun getConnectStart(): Date? = null
        override fun getConnectEnd(): Date? = null
        override fun getSslStart(): Date? = null
        override fun getSslEnd(): Date? = null
        override fun getSendingStart(): Date? = null
        override fun getSendingEnd(): Date? = null
        override fun getPushStart(): Date? = null
        override fun getPushEnd(): Date? = null
        override fun getResponseStart(): Date? = null
        override fun getSocketReused(): Boolean = false
        override fun getTtfbMs(): Long? = 12L
        override fun getTotalTimeMs(): Long? = 42L
        override fun getSentByteCount(): Long? = 100L
        override fun getReceivedByteCount(): Long? = 2048L
    }

    private class FakeResponseInfo : UrlResponseInfo() {
        override fun getUrl(): String = "https://api.example.com/v1/thing?token=abc123"
        override fun getUrlChain(): List<String> = listOf(url)
        override fun getHttpStatusCode(): Int = 200
        override fun getHttpStatusText(): String = "OK"
        override fun getAllHeadersAsList(): List<Map.Entry<String, String>> = emptyList()
        override fun getAllHeaders(): Map<String, List<String>> = mapOf(
            "Content-Type" to listOf("application/json"),
            "Set-Cookie" to listOf("sid=supersecret"),
        )
        override fun wasCached(): Boolean = false
        override fun getNegotiatedProtocol(): String = "h2"
        override fun getProxyServer(): String = ""
        override fun getReceivedByteCount(): Long = 2048L
    }

    private class FakeInfo(
        private val resp: UrlResponseInfo?,
        private val reason: Int,
        private val exc: CronetException?,
    ) : RequestFinishedInfo() {
        override fun getUrl(): String = "https://api.example.com/v1/thing?token=abc123"
        override fun getAnnotations(): Collection<Any> = emptyList()
        override fun getMetrics(): Metrics = FakeMetrics()
        override fun getFinishedReason(): Int = reason
        override fun getResponseInfo(): UrlResponseInfo? = resp
        override fun getException(): CronetException? = exc
    }

    @Test
    fun mapsSuccessToNetworkEvent() {
        val events = ArrayList<NetworkEvent>()
        val l = DrengrCronetListener(Executor { it.run() }) { events += it }
        l.onRequestFinished(FakeInfo(FakeResponseInfo(), RequestFinishedInfo.SUCCEEDED, null))
        val e = events.single()
        assertEquals(200, e.statusCode)
        assertEquals(42L, e.durationMs)
        assertEquals(100L, e.requestBodyBytes)
        assertEquals(2048L, e.responseBodyBytes)
        assertEquals("[REDACTED]", e.responseHeaders["Set-Cookie"])
        assertTrue("sensitive query param masked", e.url.contains("token=[REDACTED]"))
        assertNull(e.requestBody)
        assertNull(e.responseBody)
        assertNull(e.errorText)
        assertEquals(1720000000000L, e.timestampMs)
    }

    @Test
    fun mapsFailureToTransportError() {
        val events = ArrayList<NetworkEvent>()
        val l = DrengrCronetListener(Executor { it.run() }) { events += it }
        val exc = object : CronetException("boom", null) {}
        l.onRequestFinished(FakeInfo(null, RequestFinishedInfo.FAILED, exc))
        val e = events.single()
        assertNull(e.statusCode)
        assertNotNull(e.errorText)
    }

    @Test
    fun drengrCronetListenerIsTypedWhenCronetPresent() {
        val l = Drengr.cronetListener(Executor { it.run() })
        assertTrue(l is RequestFinishedInfo.Listener)
    }
}
