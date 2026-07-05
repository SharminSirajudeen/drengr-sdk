// Batches captured events and ships them to the ingest endpoint under a publishable key.
// Best-effort: never throws into the app, drops oldest on overflow, retries with
// exponential backoff + jitter, and persists the queue through a pluggable storage adapter.

import { nativeFetch, projectBody, type NetworkEvent } from './capture.js';
import { redactBody } from './redact.js';

// localStorage satisfies this directly; React Native AsyncStorage via its promise API.
export interface StorageAdapter {
  getItem(key: string): string | null | Promise<string | null>;
  setItem(key: string, value: string): void | Promise<void>;
  removeItem(key: string): void | Promise<void>;
}

export interface IngestSinkOptions {
  url: string;
  publishableKey: string;
  context: Record<string, unknown>;
  storage?: StorageAdapter;
  maxBatch?: number;
  maxQueue?: number;
  flushIntervalMs?: number;
}

const QUEUE_KEY = 'drengr_queue_v1';
const BASE_BACKOFF_MS = 2_000;
const MAX_BACKOFF_MS = 5 * 60_000;

export function defaultStorage(): StorageAdapter {
  try {
    const ls = (globalThis as Record<string, unknown>).localStorage as Storage | undefined;
    if (ls) {
      const probe = '__drengr_probe__';
      ls.setItem(probe, '1');
      ls.removeItem(probe);
      return ls;
    }
  } catch {}
  const mem = new Map<string, string>();
  return {
    getItem: (k) => mem.get(k) ?? null,
    setItem: (k, v) => void mem.set(k, v),
    removeItem: (k) => void mem.delete(k),
  };
}

export class IngestSink {
  private readonly url: string;
  private readonly key: string;
  private readonly context: Record<string, unknown>;
  private readonly storage: StorageAdapter;
  private readonly maxBatch: number;
  private readonly maxQueue: number;
  private readonly flushIntervalMs: number;

  private queue: Record<string, unknown>[] = [];
  private timer: ReturnType<typeof setTimeout> | null = null;
  private sending = false;
  private retries = 0;

  private persistScheduled = false;
  private persisting = false;
  private persistDirty = false;

  private externalId: string | undefined;
  private experiments: Record<string, string> = {};

  constructor(opts: IngestSinkOptions) {
    this.url = opts.url;
    this.key = opts.publishableKey;
    this.context = opts.context;
    this.storage = opts.storage ?? defaultStorage();
    this.maxBatch = opts.maxBatch ?? 50;
    this.maxQueue = opts.maxQueue ?? 500;
    this.flushIntervalMs = opts.flushIntervalMs ?? 10_000;
    void this.restore();
  }

  addNetwork = (e: NetworkEvent): void => {
    try {
      this.enqueue(this.toNet(e));
    } catch {}
  };

  // sets external_id on the session + emits one identify event; traits are redacted
  identify = (externalId: string, traits?: Record<string, unknown>): void => {
    if (typeof externalId !== 'string' || externalId.length === 0) return;
    let redactedTraits: string | null = null;
    try {
      if (traits) redactedTraits = projectBody(redactBody(JSON.stringify(traits)));
    } catch {}
    try {
      this.externalId = externalId;
      this.enqueue({
        kind: 'identify',
        event_id: randomId(),
        ts_ms: Date.now(),
        external_id: externalId,
        ...(redactedTraits != null ? { traits: redactedTraits } : {}),
      });
    } catch {}
  };

  // sets/clears a session-scoped experiment variant; null/empty clears the key
  setExperiment = (key: string, variant: string | null | undefined): void => {
    try {
      if (typeof key !== 'string' || key.length === 0) return;
      if (!variant) delete this.experiments[key];
      else this.experiments[key] = variant;
    } catch {}
  };

  private toNet(e: NetworkEvent): Record<string, unknown> {
    const status = e.statusCode ?? 0;
    const failed = e.errorText != null || status >= 400;
    const reqBody = projectBody(e.requestBody);
    const respBody = projectBody(e.responseBody);
    return {
      kind: failed ? 'net_fail' : 'net',
      event_id: randomId(),
      ts_ms: e.timestampMs,
      method: e.method,
      url: e.url,
      status,
      error_kind: failed
        ? e.errorText != null
          ? 'transport'
          : status >= 500
            ? 'server'
            : 'client'
        : '',
      duration_ms: e.durationMs,
      req_bytes: e.requestBodyBytes,
      resp_bytes: e.responseBodyBytes,
      ...(reqBody != null ? { req_body: reqBody } : {}),
      ...(respBody != null ? { body: respBody } : {}),
    };
  }

  private enqueue(ev: Record<string, unknown>): void {
    this.queue.push(ev);
    while (this.queue.length > this.maxQueue) {
      this.queue.shift();
    }
    this.schedulePersist();
    if (this.retries > 0) return; // backoff timer drives the flush
    if (this.queue.length >= this.maxBatch) {
      void this.flush();
    } else if (this.timer == null) {
      this.timer = setTimeout(() => void this.flush(), this.flushIntervalMs);
    }
  }

  async flush(): Promise<void> {
    if (this.timer != null) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    if (this.sending || this.queue.length === 0) return;
    this.sending = true;

    const batch = this.queue.splice(0, 1000);
    // sent_at_ms at send time so the server can correct clock skew
    const envelope: Record<string, unknown> = { ...this.context, sent_at_ms: Date.now(), events: batch };
    if (this.externalId) envelope.external_id = this.externalId;
    if (Object.keys(this.experiments).length > 0) envelope.experiments = { ...this.experiments };

    let acked = false;
    let permanent = false;
    try {
      const resp = await nativeFetch()(this.url, {
        method: 'POST',
        headers: {
          authorization: `Bearer ${this.key}`,
          'content-type': 'application/json',
        },
        body: JSON.stringify(envelope),
        keepalive: batch.length < 30, // survive page unload for small batches
      });
      acked = resp.status >= 200 && resp.status < 300;
      // non-retriable 4xx will never succeed; drop it so it can't head-of-line-block (429/408 still retry)
      permanent = resp.status >= 400 && resp.status < 500 && resp.status !== 429 && resp.status !== 408;
    } catch {
      acked = false;
    } finally {
      this.sending = false;
      if (acked || permanent) {
        this.retries = 0;
        this.schedulePersist();
        if (this.queue.length > 0 && this.timer == null) {
          this.timer = setTimeout(() => void this.flush(), this.flushIntervalMs);
        }
      } else {
        this.queue.unshift(...batch);
        while (this.queue.length > this.maxQueue) this.queue.pop();
        this.schedulePersist();
        this.armBackoff();
      }
    }
  }

  private armBackoff(): void {
    if (this.timer != null) clearTimeout(this.timer);
    const exp = BASE_BACKOFF_MS * 2 ** Math.min(this.retries, 20);
    const capped = Math.min(exp, MAX_BACKOFF_MS);
    const delay = BASE_BACKOFF_MS + Math.floor(Math.random() * capped);
    this.retries++;
    this.timer = setTimeout(() => void this.flush(), delay);
  }

  // persistence: writer loops until clean; an overlap marks dirty

  private schedulePersist(): void {
    if (this.persistScheduled) return;
    this.persistScheduled = true;
    queueMicrotask(() => void this.persist());
  }

  private async persist(): Promise<void> {
    this.persistScheduled = false;
    if (this.persisting) {
      this.persistDirty = true;
      return;
    }
    this.persisting = true;
    try {
      do {
        this.persistDirty = false;
        if (this.queue.length === 0) {
          await this.storage.removeItem(QUEUE_KEY);
        } else {
          await this.storage.setItem(QUEUE_KEY, JSON.stringify(this.queue));
        }
      } while (this.persistDirty);
    } catch {} finally {
      this.persisting = false;
    }
  }

  private async restore(): Promise<void> {
    try {
      const raw = await this.storage.getItem(QUEUE_KEY);
      if (!raw) return;
      const parsed = JSON.parse(raw);
      if (Array.isArray(parsed)) {
        for (const ev of parsed) {
          if (ev && typeof ev === 'object') this.queue.push(ev as Record<string, unknown>);
        }
        while (this.queue.length > this.maxQueue) this.queue.shift();
        if (this.queue.length > 0 && this.timer == null) {
          this.timer = setTimeout(() => void this.flush(), this.flushIntervalMs);
        }
      }
    } catch {}
  }
}

function randomId(): string {
  try {
    const c = (globalThis as Record<string, unknown>).crypto as Crypto | undefined;
    if (c?.randomUUID) return c.randomUUID().replace(/-/g, '');
  } catch {}
  let out = '';
  for (let i = 0; i < 32; i++) out += Math.floor(Math.random() * 16).toString(16);
  return out;
}
