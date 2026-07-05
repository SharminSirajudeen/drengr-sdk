package dev.drengr.sdk

import android.content.Context
import okhttp3.OkHttpClient
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Zero-code network analytics for Android.
 *
 *   val client = OkHttpClient.Builder()
 *       .addInterceptor(
 *           Drengr.start(
 *               context = applicationContext,
 *               publishableKey = "drengr_pk_…",
 *               ingestUrl = "https://<ref>.supabase.co/functions/v1/ingest",
 *               appPackage = "com.example.app",
 *           )
 *       )
 *       .build()
 *
 * `start` returns the [DrengrInterceptor] to add to your OkHttp client(s) — the
 * one integration point. Redaction is on by default; the sink's own delivery is
 * a separate client with no interceptor, so it can never capture itself.
 */
object Drengr {
    private val enabled = AtomicBoolean(true)
    private var sink: IngestSink? = null
    // Application context (process-lived singleton — safe to hold statically, no leak)
    // so optOut()/optIn() can persist the choice without a Context argument.
    private var appContext: Context? = null
    private const val PREFS = "drengr_sdk"
    private const val INSTALL_KEY = "install_id"
    private const val OPTOUT_KEY = "opt_out"

    const val VERSION = "0.1.0"

    /**
     * Initialize capture + delivery and return the interceptor to install on your
     * OkHttpClient. Call once at startup. Safe to call again (returns a fresh
     * interceptor bound to the same sink).
     *
     * @param maxBodyBytes cap on captured body size (default 64 KiB).
     * @param startEnabled false installs paused (consent gate); call [setEnabled].
     * @param captureWhen optional per-URL predicate (sampling / allow-listing).
     * @param redactHeaders extra header names to mask (lowercased), on top of defaults.
     */
    @JvmStatic
    @JvmOverloads
    fun start(
        context: Context,
        publishableKey: String,
        ingestUrl: String,
        appPackage: String,
        maxBodyBytes: Long = 64 * 1024,
        startEnabled: Boolean = true,
        captureWhen: ((String) -> Boolean)? = null,
        redactHeaders: Set<String> = emptySet(),
        extraContext: Map<String, Any?> = emptyMap(),
    ): DrengrInterceptor {
        val appCtx = context.applicationContext
        appContext = appCtx
        // A persisted opt-out always wins over startEnabled — an opted-out install
        // stays paused across restarts until optIn() (GDPR).
        enabled.set(startEnabled && !isOptedOut(appCtx))
        if (sink == null) {
            val ctx = HashMap<String, Any?>().apply {
                put("app_package", appPackage)
                put("os", "android")
                put("os_version", android.os.Build.VERSION.RELEASE ?: "")
                put("device_model", android.os.Build.MODEL ?: "")
                put("install_id", installId(appCtx))
                put("session_id", "s-${System.currentTimeMillis()}")
                put("sdk_version", VERSION)
                putAll(extraContext)
            }
            sink = IngestSink(appCtx.filesDir, ingestUrl, publishableKey, ctx)
        }
        val s = sink!!
        val lowerExtra = redactHeaders.map { it.lowercase() }.toSet()
        return DrengrInterceptor(
            maxBodyBytes = maxBodyBytes,
            redactHeaderNames = lowerExtra,
            onEvent = { s.addNetwork(it) },
            enabled = { enabled.get() },
            shouldCapture = { url -> captureWhen?.invoke(url) ?: true },
        )
    }

    /** Pause/resume capture (consent gate). Delivery of buffered events continues. */
    @JvmStatic
    fun setEnabled(value: Boolean) {
        enabled.set(value)
    }

    /**
     * Persistently opt this install OUT of capture (GDPR). Unlike setEnabled(false),
     * this survives app restarts — start() reads it and stays paused next launch.
     * No-op if start() hasn't run yet (no application context available).
     */
    @JvmStatic
    fun optOut() {
        appContext?.let { optOutPref(it, true) }
        enabled.set(false)
    }

    /** Reverse optOut(): clear the persisted flag and resume capture. */
    @JvmStatic
    fun optIn() {
        appContext?.let { optOutPref(it, false) }
        enabled.set(true)
    }

    /**
     * Sets external_id — your own stable, non-PII user id (not an email) — on the
     * session and all events hereafter; emits one identify event. [traits] are
     * redacted before delivery. Fail-open: no-op if [start] hasn't run yet or
     * [externalId] is empty.
     */
    @JvmStatic
    @JvmOverloads
    fun identify(externalId: String, traits: Map<String, Any?> = emptyMap()) {
        sink?.identify(externalId, traits)
    }

    /**
     * Tags the session with an experiment variant, attached to all events
     * hereafter as `experiments`. A null/empty [variant] clears [key].
     */
    @JvmStatic
    fun setExperiment(key: String, variant: String?) {
        sink?.setExperiment(key, variant)
    }

    private fun isOptedOut(ctx: Context): Boolean =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(OPTOUT_KEY, false)

    private fun optOutPref(ctx: Context, value: Boolean) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(OPTOUT_KEY, value).apply()
    }

    private fun installId(ctx: Context): String {
        val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.getString(INSTALL_KEY, null)?.let { return it }
        val id = UUID.randomUUID().toString()
        prefs.edit().putString(INSTALL_KEY, id).apply()
        return id
    }
}
