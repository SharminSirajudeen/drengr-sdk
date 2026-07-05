<img src="https://drengr.dev/mark.svg" alt="Drengr" width="72" height="72" />

# drengr-js

Zero-code network analytics for JavaScript runtimes — **Web, React Native, Electron**.
One call patches `fetch` + `XMLHttpRequest`, redacts secrets/PII in-process, and ships
every exchange to your Drengr org. No `track()` calls.

```ts
import { Drengr } from 'drengr-js';

Drengr.start({
  ingestUrl: 'https://<ref>.supabase.co/functions/v1/ingest',
  publishableKey: 'drengr_pk_…',   // from drengr.dev/pro (embed-safe)
  appPackage: 'com.example.app',
});
```

- **Redaction is on by default** (headers, URLs, JSON/form bodies; Luhn cards, JWTs, bearer tokens).
- **Delivery is invisible to capture** — the sink uses the pre-patch `fetch`, so it can never capture itself.
- **Fail-open** — capture errors never reach your app; the offline queue persists via `localStorage`
  (web/Electron) or an `AsyncStorage`-compatible adapter (React Native), with in-memory fallback.

Consent gate: `Drengr.start({ …, enabled: false })` then `Drengr.setEnabled(true)`.
