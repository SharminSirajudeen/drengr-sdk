package dev.drengr.sdk

import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Session rotation flushes the old session first; flush() force-sends now. */
class SessionFlushTest {
    private val server = MockWebServer()

    private fun newSink(sessionId: String): IngestSink {
        server.start()
        return IngestSink(
            Files.createTempDirectory("drengr-test").toFile(),
            server.url("/ingest").toString(),
            "drengr_pk_test",
            mapOf("app_package" to "test", "install_id" to "test"),
            sessionId0 = sessionId,
        )
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    private fun sampleEvent() = NetworkEvent(
        method = "GET", url = "https://api.example.com/x", statusCode = 200,
        durationMs = 5L, requestBodyBytes = 0L, responseBodyBytes = 2L,
        requestHeaders = emptyMap(), responseHeaders = emptyMap(),
        requestBody = null, responseBody = null, errorText = null,
        timestampMs = System.currentTimeMillis(),
    )

    private fun awaitEnvelope(): JSONObject {
        val req = server.takeRequest(5, TimeUnit.SECONDS)
        assertNotNull("server received a request", req)
        return JSONObject(req!!.body.readUtf8())
    }

    @Test
    fun rotationFlushesOldSessionFirst() {
        server.enqueue(MockResponse().setResponseCode(200))
        server.enqueue(MockResponse().setResponseCode(200))
        val sink = newSink("s-old")
        sink.addNetwork(sampleEvent()) // queued: default maxBatch 50, 10s timer
        sink.rotateSession("s-new")
        assertEquals("s-old", awaitEnvelope().getString("session_id"))

        sink.addNetwork(sampleEvent())
        sink.flushNow()
        assertEquals("s-new", awaitEnvelope().getString("session_id"))
    }

    @Test
    fun flushNowSendsQueueAndRunsCompletion() {
        server.enqueue(MockResponse().setResponseCode(200))
        val sink = newSink("s-1")
        sink.addNetwork(sampleEvent())
        val latch = CountDownLatch(1)
        sink.flushNow(Runnable { latch.countDown() })
        assertNotNull(server.takeRequest(5, TimeUnit.SECONDS))
        assertTrue("completion ran", latch.await(5, TimeUnit.SECONDS))
    }

    @Test
    fun drengrFlushWithoutStartRunsCompletion() {
        val latch = CountDownLatch(1)
        Drengr.flush(Runnable { latch.countDown() })
        assertTrue(latch.await(1, TimeUnit.SECONDS))
    }
}
