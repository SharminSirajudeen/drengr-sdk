/**
 * Drengr Analytics for JavaScript runtimes — Web, React Native, Electron.
 * One call captures every fetch/XHR exchange (secret/PII redaction applied
 * in-process before anything leaves the runtime) and ships it to your org's
 * ingest endpoint under a publishable key.
 *
 *   import { Drengr } from 'drengr-js';
 *   Drengr.start({
 *     ingestUrl: 'https://<ref>.supabase.co/functions/v1/ingest',
 *     publishableKey: 'drengr_pk_…',
 *     appPackage: 'com.example.app',
 *   });
 */

import {
  install,
  isInstalled,
  setEnabled,
  uninstall,
  type CaptureOptions,
  type NetworkEvent,
} from './capture.js';
import { IngestSink, defaultStorage, type StorageAdapter } from './sink.js';

export type { NetworkEvent, StorageAdapter };
export { IngestSink };
export * as redact from './redact.js';

export interface DrengrOptions {
  ingestUrl: string;
  publishableKey: string;
  /** Stable app identifier shown in the dashboard (reverse-DNS or domain). */
  appPackage: string;
  /** Extra envelope context merged over the defaults. */
  context?: Record<string, unknown>;
  /** Storage for the offline queue + install id. Default: localStorage or memory. */
  storage?: StorageAdapter;
  maxBodyBytes?: number;
  captureWhen?: CaptureOptions['captureWhen'];
  ignoreHosts?: string[];
  redactHeaders?: string[];
  /** Start paused (e.g. behind a consent gate); call setEnabled(true) later. */
  enabled?: boolean;
  /** Called after each capture, before delivery — for debugging. */
  onEvent?: (e: NetworkEvent) => void;
}

const INSTALL_KEY = 'drengr_install_id';
const OPTOUT_KEY = 'drengr_opt_out';

let sink: IngestSink | null = null;
let storageRef: StorageAdapter | null = null;

function runtimeOs(): string {
  try {
    const nav = (globalThis as Record<string, unknown>).navigator as
      | { product?: string; userAgent?: string }
      | undefined;
    if (nav?.product === 'ReactNative') return 'react-native';
    const proc = (globalThis as Record<string, unknown>).process as
      | { versions?: Record<string, string> }
      | undefined;
    if (proc?.versions?.electron) return 'electron';
    if (nav?.userAgent) return 'web';
    if (proc?.versions?.node) return 'node';
  } catch { /* fall through */ }
  return 'js';
}

function isThenable(v: unknown): boolean {
  return typeof v === 'object' && v !== null && typeof (v as { then?: unknown }).then === 'function';
}

function genId(): string {
  try {
    const c = (globalThis as Record<string, unknown>).crypto as Crypto | undefined;
    if (c?.randomUUID) return c.randomUUID();
  } catch { /* fall through */ }
  return `${Date.now().toString(16)}-${Math.random().toString(16).slice(2, 10)}`;
}

export const Drengr = {
  /** Install capture + delivery. Subsequent calls are ignored (stop() first). */
  start(options: DrengrOptions): void {
    if (isInstalled()) return;
    const storage = options.storage ?? defaultStorage();
    storageRef = storage; // so optOut()/optIn() can persist the choice after start()
    // A mutable context: on async storage (React Native's AsyncStorage) the
    // install_id resolves after start() returns, so the sink reads it lazily and
    // we backfill here before the first flush.
    const context: Record<string, unknown> = {
      app_package: options.appPackage,
      os: runtimeOs(),
      install_id: '', // filled sync (localStorage) or async (AsyncStorage) below
      session_id: `s-${Date.now()}`,
      sdk_version: SDK_VERSION,
      ...options.context,
    };
    const s = new IngestSink({
      url: options.ingestUrl,
      publishableKey: options.publishableKey,
      storage,
      context,
    });
    sink = s;

    // CONSENT-SAFE START. Sync storage (localStorage): read the opt-out NOW and
    // fold it into startPaused so an opted-out user is paused BEFORE capture goes
    // live — reading it a microtask later let same-tick requests leak. Async
    // storage (RN AsyncStorage): can't read synchronously, so start PAUSED and
    // enable only after the async read resolves (never if opted out).
    const asyncStore = isThenable(storage.getItem(INSTALL_KEY));
    const syncOptOut = !asyncStore && storage.getItem(OPTOUT_KEY) === '1';
    const startPaused = options.enabled === false || asyncStore || syncOptOut;

    // Always exclude our OWN ingest host: on React Native fetch is XHR-backed, so
    // the pre-patch fetch the sink uses still routes through the patched XHR and
    // would self-capture every delivery. Ignoring the host closes that loop.
    const ignoreHosts = new Set((options.ignoreHosts ?? []).map((h) => h.toLowerCase()));
    try {
      const ih = new URL(options.ingestUrl).host;
      if (ih) ignoreHosts.add(ih.toLowerCase());
    } catch { /* malformed ingest URL: nothing to add */ }

    install({
      maxBodyBytes: options.maxBodyBytes,
      captureWhen: options.captureWhen,
      ignoreHosts,
      redactHeaderNames: options.redactHeaders
        ? new Set(options.redactHeaders.map((h) => h.toLowerCase()))
        : undefined,
      onEvent: (e) => {
        try {
          options.onEvent?.(e);
        } catch { /* app callback must not break delivery */ }
        s.addNetwork(e);
      },
    });
    if (startPaused) setEnabled(false);

    // Resolve install_id + opt-out across BOTH sync and async storage.
    void Promise.resolve(storage.getItem(INSTALL_KEY)).then((existing) => {
      let id = typeof existing === 'string' && existing ? existing : '';
      if (!id) {
        id = genId();
        try { void storage.setItem(INSTALL_KEY, id); } catch { /* memory-only ok */ }
      }
      context.install_id = id;
    });
    void Promise.resolve(storage.getItem(OPTOUT_KEY)).then((v) => {
      if (v === '1') {
        setEnabled(false); // opted out — stay paused regardless
      } else if (options.enabled !== false && !syncOptOut) {
        setEnabled(true); // not opted out and not explicitly disabled — resume
      }
    });
  },

  /** Pause/resume capture (consent gate). Delivery of already-captured events continues. */
  setEnabled(v: boolean): void {
    setEnabled(v);
  },

  /** Persistently opt this install OUT of capture (GDPR). Unlike setEnabled(false),
   *  this survives restart: it writes the opt-out flag to storage AND pauses now, so
   *  start() reads it and stays paused on the next launch. */
  optOut(): void {
    setEnabled(false);
    try { void storageRef?.setItem(OPTOUT_KEY, '1'); } catch { /* memory-only ok */ }
  },

  /** Reverse optOut(): clear the persisted flag and resume capture. */
  optIn(): void {
    try { void storageRef?.removeItem(OPTOUT_KEY); } catch { /* memory-only ok */ }
    setEnabled(true);
  },

  /** Flush the queue now (e.g. before navigation). Best-effort. */
  flush(): Promise<void> {
    return sink?.flush() ?? Promise.resolve();
  },

  /** Sets external_id (your own stable, non-PII user id — not an email) on the
   *  session and all events hereafter; emits one identify event. traits are
   *  redacted before delivery. Fail-open: no-op if start() hasn't run or
   *  externalId is empty. */
  identify(externalId: string, traits?: Record<string, unknown>): void {
    try { sink?.identify(externalId, traits); } catch { /* fail-open */ }
  },

  /** Tags the session with an experiment variant, attached to all events
   *  hereafter as `experiments`. Pass a null/empty variant to clear the key. */
  setExperiment(key: string, variant: string | null): void {
    try { sink?.setExperiment(key, variant); } catch { /* fail-open */ }
  },

  /** Uninstall capture, restoring the runtime's own fetch/XHR. */
  stop(): void {
    uninstall();
    sink = null;
  },
};

export const SDK_VERSION = '0.1.0';
