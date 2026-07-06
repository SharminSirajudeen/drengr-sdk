package dev.drengr.sdk

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionManagerTest {
    private var now = 1_000_000_000L
    private val clock = { now }

    @Test
    fun constantsMatchSpec() {
        assertEquals(1800000L, SessionManager.SESSION_IDLE_MS)
        assertEquals(86400000L, SessionManager.SESSION_MAX_MS)
    }

    @Test
    fun freshStartMintsAndPersists() {
        val p = FakePrefs()
        val sm = SessionManager(p, clock)
        assertTrue(sm.sessionId.startsWith("s-"))
        assertEquals(sm.sessionId, p.map["session_id"])
        assertEquals(now, p.map["last_activity_at"])
    }

    @Test
    fun reusesPersistedSessionWithinIdle() {
        val p = FakePrefs()
        p.map["session_id"] = "s-persisted"
        p.map["last_activity_at"] = now - 60_000L
        p.map["session_started_at"] = now - 120_000L
        val sm = SessionManager(p, clock)
        assertEquals("s-persisted", sm.sessionId)
    }

    @Test
    fun mintsNewSessionAfterIdleGap() {
        val p = FakePrefs()
        p.map["session_id"] = "s-persisted"
        p.map["last_activity_at"] = now - SessionManager.SESSION_IDLE_MS - 1
        p.map["session_started_at"] = now - SessionManager.SESSION_IDLE_MS - 2
        val sm = SessionManager(p, clock)
        assertNotEquals("s-persisted", sm.sessionId)
        assertEquals(sm.sessionId, p.map["session_id"])
    }

    @Test
    fun mintsNewSessionPastMaxAge() {
        val p = FakePrefs()
        p.map["session_id"] = "s-persisted"
        p.map["last_activity_at"] = now - 1_000L
        p.map["session_started_at"] = now - SessionManager.SESSION_MAX_MS - 1
        val sm = SessionManager(p, clock)
        assertNotEquals("s-persisted", sm.sessionId)
    }

    @Test
    fun rotateIfStaleOnIdleGap() {
        val p = FakePrefs()
        val sm = SessionManager(p, clock)
        val old = sm.sessionId
        assertFalse(sm.rotateIfStale())
        now += SessionManager.SESSION_IDLE_MS + 1
        assertTrue(sm.rotateIfStale())
        assertNotEquals(old, sm.sessionId)
        assertEquals(sm.sessionId, p.map["session_id"])
        assertFalse(sm.rotateIfStale())
    }

    @Test
    fun rotateIfStaleOnMaxAgeDespiteActivity() {
        val p = FakePrefs()
        val sm = SessionManager(p, clock)
        val old = sm.sessionId
        var elapsed = 0L
        while (elapsed <= SessionManager.SESSION_MAX_MS) {
            now += 1_000_000L
            elapsed += 1_000_000L
            sm.touch(force = true)
            }
        assertTrue(sm.rotateIfStale())
        assertNotEquals(old, sm.sessionId)
    }

    @Test
    fun touchUpdatesLastActivity() {
        val p = FakePrefs()
        val sm = SessionManager(p, clock)
        now += 10_000L
        sm.touch(force = true)
        assertEquals(now, p.map["last_activity_at"])
    }
}
