package dev.drengr.flutter_native

import android.content.Context
import android.os.Handler
import android.os.Looper
import dev.drengr.sdk.Drengr
import dev.drengr.sdk.DrengrInterceptor
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor

/** Bridges the Flutter add-on to the native Drengr Android SDK. Fail-open throughout. */
class DrengrFlutterNativePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var appContext: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "drengr_flutter_native")
        channel?.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        appContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "start" -> result.success(start(call))
                "installUrlConnectionCapture" -> result.success(Drengr.installUrlConnectionCapture())
                // No set-session API in the native SDK yet; install_id unifies identity.
                "updateSession" -> result.success(false)
                "setEnabled" -> {
                    Drengr.setEnabled(call.argument<Boolean>("value") ?: true)
                    result.success(null)
                }
                "optOut" -> { Drengr.optOut(); result.success(null) }
                "optIn" -> { Drengr.optIn(); result.success(null) }
                "identify" -> {
                    Drengr.identify(
                        call.argument<String>("external_id") ?: "",
                        call.argument<Map<String, Any?>>("traits") ?: emptyMap(),
                    )
                    result.success(null)
                }
                "setExperiment" -> {
                    Drengr.setExperiment(
                        call.argument<String>("key") ?: "",
                        call.argument<String>("variant"),
                    )
                    result.success(null)
                }
                "flush" -> Drengr.flush {
                    Handler(Looper.getMainLooper()).post {
                        try { result.success(null) } catch (_: Throwable) {}
                    }
                }
                else -> result.notImplemented()
            }
        } catch (_: Throwable) {
            try { result.success(false) } catch (_: Throwable) {}
        }
    }

    private fun start(call: MethodCall): Boolean {
        val ctx = appContext ?: return false
        val key = call.argument<String>("publishable_key") ?: return false
        val url = call.argument<String>("ingest_url") ?: return false
        val extra = HashMap<String, Any?>()
        call.argument<String>("install_id")?.takeIf { it.isNotEmpty() }?.let { extra["install_id"] = it }
        interceptor = Drengr.start(
            context = ctx,
            publishableKey = key,
            ingestUrl = url,
            appPackage = call.argument<String>("app_package") ?: "",
            maxBodyBytes = (call.argument<Number>("max_body_bytes") ?: DEFAULT_MAX_BODY).toLong(),
            redactHeaders = (call.argument<List<String>>("redact_headers") ?: emptyList()).toSet(),
            extraContext = extra,
        )
        return true
    }

    companion object {
        private const val DEFAULT_MAX_BODY: Long = 64 * 1024

        /** OkHttp has no global hook: host-app native code adds this to its own client builders. */
        @JvmStatic
        @Volatile
        var interceptor: DrengrInterceptor? = null
            private set

        /** Cronet passthrough: a RequestFinishedInfo.Listener, or null when Cronet is absent. */
        @JvmStatic
        fun cronetListener(executor: Executor): Any? = Drengr.cronetListener(executor)
    }
}
