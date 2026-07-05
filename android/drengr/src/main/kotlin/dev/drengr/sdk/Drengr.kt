package dev.drengr.sdk

import android.content.Context
import okhttp3.OkHttpClient
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

object Drengr {
    private val enabled = AtomicBoolean(true)
    private var sink: IngestSink? = null
    private var appContext: Context? = null
    private const val PREFS = "drengr_sdk"
    private const val INSTALL_KEY = "install_id"
    private const val OPTOUT_KEY = "opt_out"

    const val VERSION = "0.1.0"

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

    @JvmStatic
    fun setEnabled(value: Boolean) {
        enabled.set(value)
    }

    @JvmStatic
    fun optOut() {
        appContext?.let { optOutPref(it, true) }
        enabled.set(false)
    }

    @JvmStatic
    fun optIn() {
        appContext?.let { optOutPref(it, false) }
        enabled.set(true)
    }

    @JvmStatic
    @JvmOverloads
    fun identify(externalId: String, traits: Map<String, Any?> = emptyMap()) {
        sink?.identify(externalId, traits)
    }

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
