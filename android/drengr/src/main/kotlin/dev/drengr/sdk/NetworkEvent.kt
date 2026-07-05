package dev.drengr.sdk

/** A single captured HTTP exchange (already redacted by the capture layer). */
data class NetworkEvent(
    val method: String,
    val url: String,
    val statusCode: Int?,
    val durationMs: Long,
    val requestBodyBytes: Long,
    val responseBodyBytes: Long,
    val requestHeaders: Map<String, String>,
    val responseHeaders: Map<String, String>,
    /** Redacted request body text (textual bodies only, capped). */
    val requestBody: String?,
    /** Redacted response body text (textual bodies only, capped). */
    val responseBody: String?,
    val errorText: String?,
    val timestampMs: Long,
)
