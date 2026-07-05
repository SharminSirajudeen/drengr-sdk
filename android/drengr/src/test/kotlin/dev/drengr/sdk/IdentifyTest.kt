package dev.drengr.sdk

import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.TimeUnit

/** Exercises identify()/setExperiment() against a real IngestSink flush over a
 *  MockWebServer (same client — OkHttp — the sink actually uses in production). */
class IdentifyTest {
    private val server = MockWebServer()

    private fun newSink(): IngestSink {
        server.start()
        return IngestSink(
            Files.createTempDirectory("drengr-test").toFile(),
            server.url("/ingest").toString(),
            "drengr_pk_test",
            mapOf("app_package" to "test", "install_id" to "test"),
            maxBatch = 1, // flush on the first enqueued event
        )
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    private fun awaitEnvelope(): JSONObject {
        val req = server.takeRequest(5, TimeUnit.SECONDS)
        assertNotNull("server received a request", req)
        server.enqueue(MockResponse().setResponseCode(200))
        return JSONObject(req!!.body.readUtf8())
    }

    private fun sampleEvent() = NetworkEvent(
        method = "GET", url = "https://api.example.com/x", statusCode = 200,
        durationMs = 5L, requestBodyBytes = 0L, responseBodyBytes = 2L,
        requestHeaders = emptyMap(), responseHeaders = emptyMap(),
        requestBody = null, responseBody = null, errorText = null,
        timestampMs = System.currentTimeMillis(),
    )

    @Test
    fun identifyEmitsEventAndAttachesExternalId() {
        server.enqueue(MockResponse().setResponseCode(200))
        val sink = newSink()
        sink.identify("user_123", mapOf("email" to "a@b.com", "plan" to "pro"))
        val envelope = awaitEnvelope()
        assertEquals("user_123", envelope.getString("external_id"))

        val events = envelope.getJSONArray("events")
        var identifyEv: JSONObject? = null
        for (i in 0 until events.length()) {
            val e = events.getJSONObject(i)
            if (e.getString("kind") == "identify") identifyEv = e
        }
        assertNotNull("identify event present", identifyEv)
        assertEquals("user_123", identifyEv!!.getString("external_id"))
        assertFalse("raw email must not appear", identifyEv.toString().contains("a@b.com"))
        assertTrue("non-PII trait survives", identifyEv.toString().contains("pro"))
    }

    @Test
    fun emptyExternalIdIsNoOp() {
        server.enqueue(MockResponse().setResponseCode(200))
        val sink = newSink()
        sink.identify("", mapOf("email" to "a@b.com"))
        assertEquals(null, server.takeRequest(300, TimeUnit.MILLISECONDS))
    }

    @Test
    fun externalIdAttachesToASubsequentEvent() {
        server.enqueue(MockResponse().setResponseCode(200))
        val sink = newSink()
        sink.identify("user_456")
        awaitEnvelope() // the identify event's own flush
        sink.addNetwork(sampleEvent())
        val envelope = awaitEnvelope()
        assertEquals("user_456", envelope.getString("external_id"))
    }

    @Test
    fun setExperimentAttachesAndClears() {
        server.enqueue(MockResponse().setResponseCode(200))
        val sink = newSink()
        sink.setExperiment("checkout_flow", "variant_b")
        sink.addNetwork(sampleEvent())
        var envelope = awaitEnvelope()
        assertEquals("variant_b", envelope.getJSONObject("experiments").getString("checkout_flow"))

        sink.setExperiment("checkout_flow", null)
        sink.addNetwork(sampleEvent())
        envelope = awaitEnvelope()
        assertFalse("experiments omitted once empty", envelope.has("experiments"))
    }

    @Test
    fun setExperimentBadInputIsNoOp() {
        server.enqueue(MockResponse().setResponseCode(200))
        val sink = newSink()
        sink.setExperiment("", "x") // must not throw
        sink.addNetwork(sampleEvent())
        val envelope = awaitEnvelope()
        assertFalse(envelope.has("experiments"))
    }
}
