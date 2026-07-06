package dev.drengr.sdk

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Fail-closed parity suite for the seal-by-default classifier (mirrors classify.ts). */
class ClassifyTest {
    private val email = "john.doe@example.com"
    private val phone = "555-123-4567"
    private val ssn = "123-45-6789"
    private val ip = "192.168.1.42"
    private val uuid = "550e8400-e29b-41d4-a716-446655440000"
    private val name = "Jonathan Q. Public"
    private val address = "221B Baker Street"
    private val leaks = listOf(email, phone, ssn, ip, uuid, name, address)

    @Test fun bodySealsAllPiiKeepsBusiness() {
        val body = """{
            "email":"$email","phone":"$phone","ssn":"$ssn","clientIp":"$ip",
            "deviceId":"$uuid","firstName":"$name","address":"$address",
            "amount":25,"currency":"USD","status":"DECLINED","ok":true,"count":3
        }"""
        val proj = Classify.classifyBody(body).projection!!
        for (leak in leaks) assertFalse("leaked: $leak", proj.contains(leak))
        val o = JSONObject(proj)
        assertEquals(25, o.getInt("amount"))
        assertEquals("USD", o.getString("currency"))
        assertEquals("DECLINED", o.getString("status"))
        assertTrue(o.getBoolean("ok"))
        assertEquals(3, o.getInt("count"))
    }

    @Test fun valueDetectedPiiUnderBenignName() {
        // benign field names, PII by value → still sealed
        val proj = Classify.classifyBody("""{"note":"$email","ref":"$ip","tag":"$uuid"}""").projection!!
        for (leak in listOf(email, ip, uuid)) assertFalse(leak, proj.contains(leak))
    }

    @Test fun typedPlaceholderPreservesType() {
        val o = JSONObject(Classify.classifyBody("""{"lat":37.77,"lng":-122.41,"count":5}""").projection!!)
        // lat/lng are PII names with numeric values → numeric placeholder, not a string
        assertEquals(0, o.getInt("lat"))
        assertEquals(0, o.getInt("lng"))
        assertEquals(5, o.getInt("count"))
    }

    @Test fun freeTextStringSealsByDefault() {
        // unknown string name, no detectable pattern → seal-by-default
        val o = JSONObject(Classify.classifyBody("""{"comment":"hello there friend","status":"OK"}""").projection!!)
        assertEquals("[PII]", o.getString("comment"))
        assertEquals("OK", o.getString("status"))
    }

    @Test fun credentialsDropped() {
        val proj = Classify.classifyBody("""{"password":"hunter2secret","card":"4111 1111 1111 1111","amount":25}""").projection!!
        assertFalse(proj.contains("hunter2secret"))
        assertFalse(proj.contains("4111"))
        assertTrue(proj.contains("REDACTED-SECRET"))
        assertEquals(25, JSONObject(proj).getInt("amount"))
    }

    @Test fun headerPiiMaskedAndValueScrubbed() {
        val out = Redact.redactHeaders(
            mapOf(
                "X-User-Email" to email,
                "X-Client-Ip" to ip,
                "X-Device-Id" to uuid,
                "Accept" to "application/json",
            ),
            emptySet(),
        )
        assertEquals("[REDACTED]", out["X-User-Email"]) // PII-denoting name → full mask
        for (leak in listOf(email, ip, uuid)) assertFalse(leak, out.values.any { it.contains(leak) })
        assertEquals("application/json", out["Accept"])
    }

    @Test fun urlPiiScrubbed() {
        val r = Redact.redactUrl("https://api.x.com/u?email=$email&ip=$ip&device=$uuid&amount=25")
        for (leak in listOf(email, ip, uuid)) assertFalse(leak, r.contains(leak))
        assertTrue(r.contains("amount=25"))
    }

    @Test fun failOpen() {
        assertNull(Classify.classifyBody("").projection)
        assertNull(Classify.classifyBody(null).projection)
        assertNull(Classify.classifyBody("not json not form").projection)
        assertNull(Classify.classifyBody("{unterminated").projection)
    }
}
