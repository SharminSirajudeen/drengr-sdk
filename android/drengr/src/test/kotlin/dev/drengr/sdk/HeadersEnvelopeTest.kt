package dev.drengr.sdk

import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import java.nio.file.Files
import java.util.concurrent.TimeUnit

/** req_headers/resp_headers ride on net events: ≤48 entries, {} when >8 KiB. */
class HeadersEnvelopeTest {
    private val server = MockWebServer()

    private fun newSink(): IngestSink {
        server.start()
        return IngestSink(
            Files.createTempDirectory("drengr-test").toFile(),
            server.url("/ingest").toString(),
            "drengr_pk_test",
            mapOf("app_package" to "test", "install_id" to "test"),
            maxBatch = 1,
        )
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    private fun awaitEnvelope(): JSONObject {
        val req = server.takeRequest(5, TimeUnit.SECONDS)
        assertNotNull("server received a request", req)
        return JSONObject(req!!.body.readUtf8())
    }

    private fun event(req: Map<String, String>, resp: Map<String, String>) = NetworkEvent(
        method = "GET", url = "https://api.example.com/x", statusCode = 200,
        durationMs = 5L, requestBodyBytes = 0L, responseBodyBytes = 2L,
        requestHeaders = req, responseHeaders = resp,
        requestBody = null, responseBody = null, errorText = null,
        timestampMs = System.currentTimeMillis(),
    )

    @Test
    fun headersRideAlongOnNetEvents() {
        server.enqueue(MockResponse().setResponseCode(200))
        val sink = newSink()
        sink.addNetwork(
            event(
                req = mapOf("Content-Type" to "application/json", "Authorization" to "[REDACTED]"),
                resp = mapOf("Content-Type" to "application/json"),
            ),
        )
        val ev = awaitEnvelope().getJSONArray("events").getJSONObject(0)
        val reqH = ev.getJSONObject("req_headers")
        assertEquals("application/json", reqH.getString("Content-Type"))
        assertEquals("[REDACTED]", reqH.getString("Authorization"))
        assertEquals("application/json", ev.getJSONObject("resp_headers").getString("Content-Type"))
    }

    @Test
    fun headersCapAt48Entries() {
        server.enqueue(MockResponse().setResponseCode(200))
        val sink = newSink()
        sink.addNetwork(event(req = (1..60).associate { "h$it" to "v$it" }, resp = emptyMap()))
        val ev = awaitEnvelope().getJSONArray("events").getJSONObject(0)
        assertEquals(48, ev.getJSONObject("req_headers").length())
        assertEquals(0, ev.getJSONObject("resp_headers").length())
    }

    @Test
    fun oversizedHeadersCollapseToEmptyObject() {
        server.enqueue(MockResponse().setResponseCode(200))
        val sink = newSink()
        sink.addNetwork(
            event(
                req = (1..6).associate { "h$it" to "x".repeat(2000) },
                resp = mapOf("Content-Type" to "text/plain"),
            ),
        )
        val ev = awaitEnvelope().getJSONArray("events").getJSONObject(0)
        assertEquals(0, ev.getJSONObject("req_headers").length())
        assertEquals(1, ev.getJSONObject("resp_headers").length())
    }
}
