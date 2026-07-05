// Drengr Analytics for JS runtimes (Web, React Native, Electron): one start() call
// captures every fetch/XHR exchange, redacts in-process, and ships under a publishable key.

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
  appPackage: string;
  context?: Record<string, unknown>;
  storage?: StorageAdapter;
  maxBodyBytes?: number;
  captureWhen?: CaptureOptions['captureWhen'];
  ignoreHosts?: string[];
  redactHeaders?: string[];
  enabled?: boolean;
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
  } catch {}
  return 'js';
}

function isThenable(v: unknown): boolean {
  return typeof v === 'object' && v !== null && typeof (v as { then?: unknown }).then === 'function';
}

function genId(): string {
  try {
    const c = (globalThis as Record<string, unknown>).crypto as Crypto | undefined;
    if (c?.randomUUID) return c.randomUUID();
  } catch {}
  return `${Date.now().toString(16)}-${Math.random().toString(16).slice(2, 10)}`;
}

export const Drengr = {
  start(options: DrengrOptions): void {
    if (isInstalled()) return;
    const storage = options.storage ?? defaultStorage();
    storageRef = storage;
    // install_id may resolve async (RN AsyncStorage); the sink reads it lazily, backfilled here
    const context: Record<string, unknown> = {
      app_package: options.appPackage,
      os: runtimeOs(),
      install_id: '',
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

    // consent-safe: read sync opt-out now so an opted-out user is paused before capture;
    // async storage can't read synchronously, so start paused and enable after it resolves
    const asyncStore = isThenable(storage.getItem(INSTALL_KEY));
    const syncOptOut = !asyncStore && storage.getItem(OPTOUT_KEY) === '1';
    const startPaused = options.enabled === false || asyncStore || syncOptOut;

    // always exclude our own ingest host (on RN the sink's fetch routes through patched XHR)
    const ignoreHosts = new Set((options.ignoreHosts ?? []).map((h) => h.toLowerCase()));
    try {
      const ih = new URL(options.ingestUrl).host;
      if (ih) ignoreHosts.add(ih.toLowerCase());
    } catch {}

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
        } catch {}
        s.addNetwork(e);
      },
    });
    if (startPaused) setEnabled(false);

    void Promise.resolve(storage.getItem(INSTALL_KEY)).then((existing) => {
      let id = typeof existing === 'string' && existing ? existing : '';
      if (!id) {
        id = genId();
        try { void storage.setItem(INSTALL_KEY, id); } catch {}
      }
      context.install_id = id;
    });
    void Promise.resolve(storage.getItem(OPTOUT_KEY)).then((v) => {
      if (v === '1') {
        setEnabled(false);
      } else if (options.enabled !== false && !syncOptOut) {
        setEnabled(true);
      }
    });
  },

  setEnabled(v: boolean): void {
    setEnabled(v);
  },

  // persistent opt-out (GDPR): survives restart; start() reads the flag and stays paused
  optOut(): void {
    setEnabled(false);
    try { void storageRef?.setItem(OPTOUT_KEY, '1'); } catch {}
  },

  optIn(): void {
    try { void storageRef?.removeItem(OPTOUT_KEY); } catch {}
    setEnabled(true);
  },

  flush(): Promise<void> {
    return sink?.flush() ?? Promise.resolve();
  },

  identify(externalId: string, traits?: Record<string, unknown>): void {
    try { sink?.identify(externalId, traits); } catch {}
  },

  setExperiment(key: string, variant: string | null): void {
    try { sink?.setExperiment(key, variant); } catch {}
  },

  stop(): void {
    uninstall();
    sink = null;
  },
};

export const SDK_VERSION = '0.1.0';
