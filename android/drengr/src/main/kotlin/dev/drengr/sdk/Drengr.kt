package dev.drengr.sdk

import android.app.Activity
import android.app.Application
import android.content.Context
import android.os.Bundle
import okhttp3.OkHttpClient
import java.util.UUID
import java.util.concurrent.Executor
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
    private var session: SessionManager? = null
    // Application context (process-lived singleton — safe to hold statically, no leak)
    // so optOut()/optIn() can persist the choice without a Context argument.
    private var appContext: Context? = null
    private val lifecycleRegistered = AtomicBoolean(false)
    @Volatile private var redactExtra: Set<String> = emptySet()
    @Volatile private var maxBody: Long = 64 * 1024
    private const val PREFS = "drengr_sdk"
    private const val INSTALL_KEY = "install_id"
    private const val OPTOUT_KEY = "opt_out"

    const val VERSION = "0.2.0"

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
            val sm = try {
                SessionManager(appCtx.getSharedPreferences(PREFS, Context.MODE_PRIVATE))
            } catch (_: Throwable) { null }
            session = sm
            val ctx = HashMap<String, Any?>().apply {
                put("app_package", appPackage)
                put("os", "android")
                put("os_version", android.os.Build.VERSION.RELEASE ?: "")
                put("device_model", android.os.Build.MODEL ?: "")
                put("install_id", installId(appCtx))
                put("sdk_version", VERSION)
                putAll(extraContext)
            }
            sink = IngestSink(
                appCtx.filesDir, ingestUrl, publishableKey, ctx,
                sessionId0 = sm?.sessionId ?: "s-${System.currentTimeMillis()}",
            )
            registerLifecycle(appCtx)
        }
        val s = sink!!
        redactExtra = redactHeaders.map { it.lowercase() }.toSet()
        maxBody = maxBodyBytes
        return DrengrInterceptor(
            maxBodyBytes = maxBodyBytes,
            redactHeaderNames = redactExtra,
            onEvent = { session?.touch(); s.addNetwork(it) },
            enabled = { enabled.get() },
            shouldCapture = { url -> captureWhen?.invoke(url) ?: true },
        )
    }

    /** Force-send buffered events now. [onComplete] runs after the attempt. */
    @JvmStatic
    @JvmOverloads
    fun flush(onComplete: Runnable? = null) {
        val s = sink
        if (s == null) {
            try { onComplete?.run() } catch (_: Throwable) {}
            return
        }
        s.flushNow(onComplete)
    }

    /**
     * Opt-in HttpURLConnection/HttpsURLConnection capture via a process-global
     * delegating URLStreamHandlerFactory (set-once per process). Call after
     * [start]. Returns false — with one logged warning, never a crash — when
     * another factory already owns the process. Captured exchanges go through
     * the same redaction + delivery path as the OkHttp interceptor.
     */
    @JvmStatic
    fun installUrlConnectionCapture(): Boolean {
        val s = sink ?: return false
        return UrlConnectionCapture.install(
            onEvent = { session?.touch(); s.addNetwork(it) },
            enabled = { enabled.get() },
            redactExtra = redactExtra,
            maxBodyBytes = maxBody,
        )
    }

    /**
     * Cronet adapter (opt-in): returns a `RequestFinishedInfo.Listener` to pass to
     * `CronetEngine.Builder.addRequestFinishedListener`, or null when Cronet is not
     * on the classpath (clean no-op — the SDK never hard-requires Cronet). Typed
     * `Any?` so this method resolves without Cronet present.
     */
    @JvmStatic
    fun cronetListener(executor: Executor): Any? = try {
        Class.forName("org.chromium.net.RequestFinishedInfo")
        DrengrCronetListener(executor) { e ->
            if (enabled.get()) {
                session?.touch()
                sink?.addNetwork(e)
            }
        }
    } catch (_: Throwable) {
        null
    }

    /**
     * EXPERIMENTAL — Compose semantic tap capture. Wraps the activity's window
     * callback to observe taps and resolve the tapped Compose node's semantics
     * (contentDescription/text/role) into labeled tap events. Returns false —
     * never a crash — when compose-ui is absent (clean no-op, compose is never
     * hard-required), [start] hasn't run, or the window isn't ready. Fail-open:
     * touch delivery to the app is never affected.
     */
    @JvmStatic
    fun experimentalComposeTapCapture(activity: Activity): Boolean {
        return try {
            Class.forName("androidx.compose.ui.semantics.SemanticsOwner")
            val s = sink ?: return false
            ComposeTapCapture.install(activity) { e ->
                if (enabled.get()) {
                    session?.touch()
                    s.addTap(e)
                }
            }
        } catch (_: Throwable) {
            false
        }
    }

    /** EXPERIMENTAL — restore the window callback wrapped by [experimentalComposeTapCapture]. */
    @JvmStatic
    fun experimentalComposeTapCaptureStop(activity: Activity): Boolean {
        return try {
            Class.forName("androidx.compose.ui.semantics.SemanticsOwner")
            ComposeTapCapture.uninstall(activity)
        } catch (_: Throwable) {
            false
        }
    }

    private fun registerLifecycle(ctx: Context) {
        if (!lifecycleRegistered.compareAndSet(false, true)) return
        try {
            (ctx as? Application)?.registerActivityLifecycleCallbacks(lifecycle)
        } catch (_: Throwable) {}
    }

    // Foreground = zero→nonzero started activities (rotate stale session);
    // background = nonzero→zero (persist activity + auto-flush).
    private val lifecycle = object : Application.ActivityLifecycleCallbacks {
        private var started = 0

        override fun onActivityStarted(activity: Activity) {
            if (started++ != 0) return
            try {
                val sm = session ?: return
                if (sm.rotateIfStale()) sink?.rotateSession(sm.sessionId)
            } catch (_: Throwable) {}
        }

        override fun onActivityStopped(activity: Activity) {
            if (started > 0) started--
            if (started != 0) return
            try { session?.touch(force = true) } catch (_: Throwable) {}
            try { sink?.flushNow() } catch (_: Throwable) {}
        }

        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
        override fun onActivityResumed(activity: Activity) {}
        override fun onActivityPaused(activity: Activity) {}
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
        override fun onActivityDestroyed(activity: Activity) {}
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
