package dev.drengr.sdk

import android.content.SharedPreferences

/**
 * Session identity with idle/max-age rotation, persisted in SharedPreferences.
 * On construction: reuse the persisted session_id while the idle gap is under
 * [SESSION_IDLE_MS] and the session is younger than [SESSION_MAX_MS], else mint.
 * Fail-open: any storage error falls back to a fresh in-memory session.
 */
internal class SessionManager(
    private val prefs: SharedPreferences,
    private val now: () -> Long = System::currentTimeMillis,
) {
    @Volatile
    var sessionId: String
        private set

    @Volatile
    private var startedAt: Long

    @Volatile
    private var lastTouchWrite = 0L

    init {
        val t = now()
        val persisted = try { prefs.getString(SESSION_KEY, null) } catch (_: Throwable) { null }
        val last = try { prefs.getLong(LAST_ACTIVITY_KEY, 0L) } catch (_: Throwable) { 0L }
        val started = try { prefs.getLong(STARTED_KEY, 0L) } catch (_: Throwable) { 0L }
        if (persisted != null && t - last < SESSION_IDLE_MS && t - started < SESSION_MAX_MS) {
            sessionId = persisted
            startedAt = if (started > 0L) started else t
        } else {
            sessionId = "s-$t"
            startedAt = t
            persistSession(t)
        }
        touch(force = true)
    }

    /** Update last_activity_at (throttled to one write per 5s unless [force]d). */
    fun touch(force: Boolean = false) {
        val t = now()
        if (!force && t - lastTouchWrite < TOUCH_THROTTLE_MS) return
        lastTouchWrite = t
        try { prefs.edit().putLong(LAST_ACTIVITY_KEY, t).apply() } catch (_: Throwable) {}
    }

    /** Mint a new session if the idle gap or max age is exceeded. True if rotated. */
    fun rotateIfStale(): Boolean {
        val t = now()
        val last = try { prefs.getLong(LAST_ACTIVITY_KEY, t) } catch (_: Throwable) { t }
        if (t - last <= SESSION_IDLE_MS && t - startedAt <= SESSION_MAX_MS) return false
        sessionId = "s-$t"
        startedAt = t
        persistSession(t)
        touch(force = true)
        return true
    }

    private fun persistSession(t: Long) {
        try {
            prefs.edit().putString(SESSION_KEY, sessionId).putLong(STARTED_KEY, t).apply()
        } catch (_: Throwable) {}
    }

    companion object {
        const val SESSION_IDLE_MS = 1800000L
        const val SESSION_MAX_MS = 86400000L
        private const val TOUCH_THROTTLE_MS = 5000L
        private const val SESSION_KEY = "session_id"
        private const val LAST_ACTIVITY_KEY = "last_activity_at"
        private const val STARTED_KEY = "session_started_at"
    }
}
