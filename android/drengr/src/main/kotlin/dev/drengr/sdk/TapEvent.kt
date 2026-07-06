package dev.drengr.sdk

/** A single captured semantic tap (label already redacted by the capture layer). */
data class TapEvent(
    val label: String,
    val role: String?,
    /** Where the label came from, e.g. "compose_semantics". */
    val source: String,
    /** Tap position in window coordinates (px). */
    val x: Float,
    val y: Float,
    /** Activity class name at tap time. */
    val screen: String?,
    val timestampMs: Long,
)
