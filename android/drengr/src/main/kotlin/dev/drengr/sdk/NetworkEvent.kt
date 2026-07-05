package dev.drengr.sdk

data class NetworkEvent(
    val method: String,
    val url: String,
    val statusCode: Int?,
    val durationMs: Long,
    val requestBodyBytes: Long,
    val responseBodyBytes: Long,
    val requestHeaders: Map<String, String>,
    val responseHeaders: Map<String, String>,
    val requestBody: String?,
    val responseBody: String?,
    val errorText: String?,
    val timestampMs: Long,
)
