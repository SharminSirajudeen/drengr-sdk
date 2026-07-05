# Drengr Android SDK

Zero-code network analytics for Android — one interceptor captures every OkHttp/
Retrofit exchange (secret/PII redaction in-process), no `track()` calls.

```kotlin
val client = OkHttpClient.Builder()
    .addInterceptor(
        Drengr.start(
            context = applicationContext,
            publishableKey = "drengr_pk_…",              // from drengr.dev/pro (embed-safe)
            ingestUrl = "https://<ref>.supabase.co/functions/v1/ingest",
            appPackage = "com.example.app",
        )
    )
    .build()
```

Covers OkHttp + Retrofit (the majority of Android networking). Not covered: raw
sockets, Cronet, `HttpURLConnection` (wrapper planned). Redaction is on by default;
delivery uses a separate client with no interceptor, so it can never capture itself.
Consent gate: `Drengr.start(..., startEnabled = false)` then `Drengr.setEnabled(true)`.
