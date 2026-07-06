package dev.drengr.sdk

import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Test
import java.nio.file.Files
import java.util.concurrent.TimeUnit

/** Tap events ride the existing sink path as a NetworkEvent-sibling (kind=tap). */
class TapEventSinkTest {
    private val server = MockWebServer()

    @After
    fun tearDown() {
        server.shutdown()
    }

    @Test
    fun tapEventDeliveredWithLabelRoleAndScreen() {
        server.enqueue(MockResponse().setResponseCode(200))
        server.start()
        val sink = IngestSink(
            Files.createTempDirectory("drengr-test").toFile(),
            server.url("/ingest").toString(),
            "drengr_pk_test",
            mapOf("app_package" to "test", "install_id" to "test"),
            sessionId0 = "s-tap",
        )
        sink.addTap(
            TapEvent(
                label = "Add to cart",
                role = "Button",
                source = "compose_semantics",
                x = 120.5f,
                y = 640f,
                screen = "com.example.MainActivity",
                timestampMs = 1234L,
            ),
        )
        sink.flushNow()
        val req = server.takeRequest(5, TimeUnit.SECONDS)
        assertNotNull(req)
        val envelope = JSONObject(req!!.body.readUtf8())
        assertEquals("s-tap", envelope.getString("session_id"))
        val ev = envelope.getJSONArray("events").getJSONObject(0)
        assertEquals("tap", ev.getString("kind"))
        assertEquals("Add to cart", ev.getString("label"))
        assertEquals("Button", ev.getString("role"))
        assertEquals("compose_semantics", ev.getString("source"))
        assertEquals("com.example.MainActivity", ev.getString("screen"))
        assertEquals(1234L, ev.getLong("ts_ms"))
        assertEquals(120.5, ev.getDouble("x"), 0.001)
        assertEquals(640.0, ev.getDouble("y"), 0.001)
        assertFalse(ev.getString("event_id").isEmpty())
    }

    @Test
    fun nullRoleAndScreenAreOmitted() {
        server.enqueue(MockResponse().setResponseCode(200))
        server.start()
        val sink = IngestSink(
            Files.createTempDirectory("drengr-test").toFile(),
            server.url("/ingest").toString(),
            "drengr_pk_test",
            mapOf("app_package" to "test", "install_id" to "test"),
            sessionId0 = "s-tap2",
        )
        sink.addTap(TapEvent("Login", null, "compose_semantics", 1f, 2f, null, 5L))
        sink.flushNow()
        val req = server.takeRequest(5, TimeUnit.SECONDS)
        assertNotNull(req)
        val ev = JSONObject(req!!.body.readUtf8()).getJSONArray("events").getJSONObject(0)
        assertEquals("tap", ev.getString("kind"))
        assertFalse(ev.has("role"))
        assertFalse(ev.has("screen"))
    }
}
