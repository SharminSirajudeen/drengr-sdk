package dev.drengr.sdk

import org.chromium.net.RequestFinishedInfo
import java.util.concurrent.Executor

/**
 * Cronet request-finished adapter. Cronet exposes no bodies, so this maps
 * url/status/sizes/timing only (body fields null). Obtain via
 * [Drengr.cronetListener] and register on your `CronetEngine.Builder`.
 * Cronet is compileOnly: this class loads only when Cronet is present.
 */
class DrengrCronetListener internal constructor(
    executor: Executor,
    private val onEvent: (NetworkEvent) -> Unit,
) : RequestFinishedInfo.Listener(executor) {

    override fun onRequestFinished(info: RequestFinishedInfo?) {
        try {
            info ?: return
            val resp = info.responseInfo
            val m = info.metrics
            val headers = LinkedHashMap<String, String>()
            try {
                resp?.allHeaders?.forEach { (k, vs) ->
                    if (k != null && vs != null) headers[k] = vs.joinToString(", ")
                }
            } catch (_: Throwable) {}
            val failed = info.finishedReason != RequestFinishedInfo.SUCCEEDED && resp == null
            onEvent(
                NetworkEvent(
                    method = "",
                    url = Redact.redactUrl(info.url ?: ""),
                    statusCode = resp?.httpStatusCode,
                    durationMs = m?.totalTimeMs ?: 0L,
                    requestBodyBytes = m?.sentByteCount ?: 0L,
                    responseBodyBytes = m?.receivedByteCount ?: (resp?.receivedByteCount ?: 0L),
                    requestHeaders = emptyMap(),
                    responseHeaders = Redact.redactHeaders(headers, emptySet()),
                    requestBody = null,
                    responseBody = null,
                    errorText = if (failed) (info.exception?.javaClass?.simpleName ?: "cronet") else null,
                    timestampMs = m?.requestStart?.time ?: System.currentTimeMillis(),
                ),
            )
        } catch (_: Throwable) {}
    }
}
