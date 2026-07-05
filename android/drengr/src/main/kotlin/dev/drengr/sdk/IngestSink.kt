package dev.drengr.sdk

import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.ArrayDeque
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import kotlin.math.min
import kotlin.random.Random

/**
 * Batches captured signals and ships them to the Drengr ingest endpoint,
 * authenticated by a publishable key. Port of the proven Dart/JS IngestSink,
 * carrying every device-run lesson from birth:
 *  - delivery uses a DEDICATED OkHttpClient with NO Drengr interceptor, so the
 *    sink can never capture its own POSTs (the self-capture loop can't exist);
 *  - the persist scheduler serializes writes on a single-thread executor, so no
 *    starvation loop is possible;
 *  - envelope carries sent_at_ms for server-side clock-skew correction.
 *
 * Best-effort and non-blocking: never throws into the app, drops oldest on
 * overflow, retries with exponential backoff + full jitter, persists the queue
 * to a JSONL file in the app's files dir so an app kill doesn't lose events.
 */
internal class IngestSink(
    filesDir: File,
    private val url: String,
    private val publishableKey: String,
    private val context0: Map<String, Any?>,
    private val maxBatch: Int = 50,
    private val maxQueue: Int = 500,
    private val flushIntervalMs: Long = 10_000,
) {
    // A single-thread executor is the whole concurrency model: enqueue, flush,
    // persist, and restore all run here, so the in-memory queue needs no locks
    // and no write can overlap another (no starvation loop).
    private val exec: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "drengr-sink").apply { isDaemon = true }
    }
    private val queue = ArrayDeque<JSONObject>()
    private val file = File(filesDir, "drengr_queue.jsonl")
    private var flushScheduled = false
    private var retries = 0

    // Session-scoped identity/experiment state, merged into every envelope (see flush()).
    // Mutated only on `exec` (identify/setExperiment dispatch there), same as the queue.
    private var externalId: String? = null
    private val experiments = LinkedHashMap<String, String>()

    // Delivery client: NO interceptor → structurally invisible to capture.
    private val delivery = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .callTimeout(30, TimeUnit.SECONDS)
        .build()

    init {
        exec.execute { restore() }
    }

    fun addNetwork(e: NetworkEvent) {
        val ev = try { toNet(e) } catch (_: Throwable) { return }
        exec.execute { enqueue(ev) }
    }

    /** Sets external_id (all events hereafter) and emits one identify event; traits
     *  go through the same redact+project pipeline as bodies. Fail-open. */
    fun identify(externalId: String, traits: Map<String, Any?> = emptyMap()) {
        if (externalId.isEmpty()) return
        val redactedTraits = try {
            Redact.projectBody(Redact.redactBody(JSONObject(traits).toString()))
        } catch (_: Throwable) { null }
        val ev = try {
            JSONObject().apply {
                put("kind", "identify")
                put("event_id", randomId())
                put("ts_ms", System.currentTimeMillis())
                put("external_id", externalId)
                redactedTraits?.let { put("traits", it) }
            }
        } catch (_: Throwable) { return }
        exec.execute {
            this.externalId = externalId
            enqueue(ev)
        }
    }

    /** Sets/clears a session-scoped experiment variant (all events hereafter, as
     *  `experiments`). A null/empty variant clears the key. Fail-open. */
    fun setExperiment(key: String, variant: String?) {
        if (key.isEmpty()) return
        exec.execute {
            if (variant.isNullOrEmpty()) experiments.remove(key) else experiments[key] = variant
        }
    }

    private fun toNet(e: NetworkEvent): JSONObject {
        val status = e.statusCode ?: 0
        val failed = e.errorText != null || status >= 400
        val o = JSONObject()
        o.put("kind", if (failed) "net_fail" else "net")
        o.put("event_id", randomId())
        o.put("ts_ms", e.timestampMs)
        o.put("method", e.method)
        o.put("url", e.url)
        o.put("status", status)
        o.put(
            "error_kind",
            if (failed) (if (e.errorText != null) "transport" else if (status >= 500) "server" else "client") else "",
        )
        o.put("duration_ms", e.durationMs)
        o.put("req_bytes", e.requestBodyBytes)
        o.put("resp_bytes", e.responseBodyBytes)
        Redact.projectBody(e.requestBody)?.let { o.put("req_body", it) }
        Redact.projectBody(e.responseBody)?.let { o.put("body", it) }
        return o
    }

    private fun enqueue(ev: JSONObject) {
        queue.addLast(ev)
        while (queue.size > maxQueue) queue.pollFirst()
        schedulePersist()
        if (retries > 0) return
        if (queue.size >= maxBatch) flush() else scheduleFlush()
    }

    private fun scheduleFlush() {
        if (flushScheduled) return
        flushScheduled = true
        exec.schedule({ flushScheduled = false; flush() }, flushIntervalMs, TimeUnit.MILLISECONDS)
    }

    private fun flush() {
        if (queue.isEmpty()) return
        val batch = ArrayList<JSONObject>(min(queue.size, 1000))
        while (queue.isNotEmpty() && batch.size < 1000) batch.add(queue.pollFirst())

        val envelope = JSONObject()
        for ((k, v) in context0) envelope.put(k, v ?: JSONObject.NULL)
        envelope.put("sent_at_ms", System.currentTimeMillis())
        envelope.put("events", JSONArray(batch))
        externalId?.let { envelope.put("external_id", it) }
        if (experiments.isNotEmpty()) envelope.put("experiments", JSONObject(experiments))

        var acked = false
        var permanent = false
        try {
            val req = Request.Builder()
                .url(url)
                .header("authorization", "Bearer $publishableKey")
                .post(envelope.toString().toRequestBody(JSON))
                .build()
            delivery.newCall(req).execute().use { resp ->
                acked = resp.isSuccessful
                // Non-retriable 4xx (revoked key 401, bad batch 400/413) never
                // succeeds — retrying forever head-of-line-blocks the queue. Drop.
                permanent = resp.code in 400..499 && resp.code != 429 && resp.code != 408
            }
        } catch (_: Throwable) {
            acked = false
        }

        if (acked || permanent) {
            retries = 0 // batch consumed (delivered or dropped as permanent)
            schedulePersist()
            if (queue.isNotEmpty()) scheduleFlush()
        } else {
            // Requeue at the front; shed newest on overflow.
            for (i in batch.indices.reversed()) queue.addFirst(batch[i])
            while (queue.size > maxQueue) queue.pollLast()
            schedulePersist()
            armBackoff()
        }
    }

    private fun armBackoff() {
        val exp = BASE_BACKOFF_MS * (1L shl min(retries, 20))
        val capped = min(exp, MAX_BACKOFF_MS)
        val delay = BASE_BACKOFF_MS + Random.nextLong(capped)
        retries++
        exec.schedule({ flush() }, delay, TimeUnit.MILLISECONDS)
    }

    // --- persistence (serialized on exec; writer loops nothing — one write per tick) ---
    private fun schedulePersist() {
        if (flushScheduled) { /* a flush is queued; persist will ride along */ }
        exec.execute { persist() }
    }

    private fun persist() {
        try {
            if (queue.isEmpty()) {
                if (file.exists()) file.delete()
            } else {
                val tmp = File(file.parentFile, file.name + ".tmp")
                tmp.bufferedWriter().use { w ->
                    for (ev in queue) { w.write(ev.toString()); w.newLine() }
                }
                tmp.renameTo(file)
            }
        } catch (_: Throwable) { /* best-effort */ }
    }

    private fun restore() {
        try {
            if (!file.exists()) return
            file.forEachLine { line ->
                if (line.isNotBlank() && queue.size < maxQueue) {
                    try { queue.addLast(JSONObject(line)) } catch (_: Throwable) {}
                }
            }
            if (queue.isNotEmpty()) scheduleFlush()
        } catch (_: Throwable) { /* corrupt/missing → start empty */ }
    }

    private fun randomId(): String {
        val sb = StringBuilder(32)
        repeat(16) { sb.append("%02x".format(Random.nextInt(256))) }
        return sb.toString()
    }

    companion object {
        private const val BASE_BACKOFF_MS = 2_000L
        private const val MAX_BACKOFF_MS = 5 * 60_000L
        private val JSON = "application/json; charset=utf-8".toMediaTypeOrNull()
    }
}
