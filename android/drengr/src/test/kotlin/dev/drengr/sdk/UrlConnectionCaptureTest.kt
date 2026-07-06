package dev.drengr.sdk

import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.CopyOnWriteArrayList

/** HttpURLConnection capture through the delegating handler, against MockWebServer. */
class UrlConnectionCaptureTest {
    private val server = MockWebServer()
    private val events = CopyOnWriteArrayList<NetworkEvent>()

    @Before
    fun setUp() {
        server.start()
        UrlConnectionCapture.bind({ events += it }, { true }, emptySet(), 64 * 1024)
    }

    @After
    fun tearDown() {
        try { server.shutdown() } catch (_: Throwable) {}
    }

    private fun connect(path: String): HttpURLConnection {
        val handler = CapturingHandler(URL("http://drengr.invalid/"), 80)
        return URL(null, server.url(path).toString(), handler).openConnection() as HttpURLConnection
    }

    private fun awaitEvent(): NetworkEvent {
        val deadline = System.currentTimeMillis() + 5_000
        while (events.isEmpty() && System.currentTimeMillis() < deadline) Thread.sleep(10)
        assertTrue("event captured", events.isNotEmpty())
        return events[0]
    }

    @Test
    fun getIsCaptured() {
        server.enqueue(MockResponse().setBody("""{"ok":true}""").setHeader("Content-Type", "application/json"))
        val c = connect("/v1/ok")
        assertEquals(200, c.responseCode)
        assertEquals("""{"ok":true}""", String(c.inputStream.readBytes()))
        val e = awaitEvent()
        assertEquals("GET", e.method)
        assertEquals(200, e.statusCode)
        assertTrue(e.url.contains("/v1/ok"))
        assertEquals("""{"ok":true}""", e.responseBody)
        assertTrue(e.responseBodyBytes > 0)
        assertNull(e.errorText)
    }

    @Test
    fun postBodyCapturedAndRedactedAppUntouched() {
        server.enqueue(MockResponse().setResponseCode(201).setBody("{}").setHeader("Content-Type", "application/json"))
        val body = """{"password":"hunter2","plan":"pro"}"""
        val c = connect("/v1/users")
        c.requestMethod = "POST"
        c.doOutput = true
        c.setRequestProperty("Content-Type", "application/json")
        c.setRequestProperty("Authorization", "Bearer secret-token-123")
        c.outputStream.use { it.write(body.toByteArray()) }
        c.inputStream.readBytes()
        val e = awaitEvent()
        assertEquals("POST", e.method)
        assertEquals(201, e.statusCode)
        assertEquals("[REDACTED]", e.requestHeaders["Authorization"])
        assertFalse("secret must not survive", e.requestBody!!.contains("hunter2"))
        assertTrue(e.requestBody!!.contains("[REDACTED]"))
        assertTrue(e.requestBody!!.contains("pro"))
        assertEquals(body.length.toLong(), e.requestBodyBytes)
        // the wire saw the untouched body
        assertEquals(body, server.takeRequest().body.readUtf8())
    }

    @Test
    fun httpErrorStatusCaptured() {
        server.enqueue(MockResponse().setResponseCode(404).setBody("""{"error":"nope"}""").setHeader("Content-Type", "application/json"))
        val c = connect("/missing")
        assertEquals(404, c.responseCode)
        c.errorStream?.readBytes()
        val e = awaitEvent()
        assertEquals(404, e.statusCode)
        assertNull(e.errorText)
    }

    @Test
    fun transportErrorEmitsFailure() {
        val url = server.url("/dead").toString()
        server.shutdown()
        val handler = CapturingHandler(URL("http://drengr.invalid/"), 80)
        val c = URL(null, url, handler).openConnection() as HttpURLConnection
        c.connectTimeout = 2_000
        c.readTimeout = 2_000
        try {
            c.responseCode
            fail("expected IOException")
        } catch (_: IOException) {}
        val e = awaitEvent()
        assertNull(e.statusCode)
        assertNotNull(e.errorText)
    }

    @Test
    fun installIsIdempotentAndCapturesThroughGlobalFactory() {
        assertTrue(UrlConnectionCapture.install({ events += it }, { true }, emptySet(), 64 * 1024))
        assertTrue(UrlConnectionCapture.install({ events += it }, { true }, emptySet(), 64 * 1024))
        server.enqueue(MockResponse().setBody("ok").setHeader("Content-Type", "text/plain"))
        val c = URL(server.url("/global").toString()).openConnection() as HttpURLConnection
        assertEquals(200, c.responseCode)
        c.inputStream.readBytes()
        val deadline = System.currentTimeMillis() + 5_000
        while (events.none { it.url.contains("/global") } && System.currentTimeMillis() < deadline) Thread.sleep(10)
        assertTrue(events.any { it.url.contains("/global") && it.statusCode == 200 })
    }
}
