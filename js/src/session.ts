/**
 * Session rotation: reuse the persisted session across restarts while fresh,
 * rotate after an idle gap or max age. On rotation the pending queue is flushed
 * under the OLD session_id first (flush snapshots the envelope synchronously),
 * then a new id is minted. Fail-open throughout.
 */

import type { StorageAdapter } from './sink.js';

export const SESSION_IDLE_MS = 1800000;
export const SESSION_MAX_MS = 86400000;

const SESSION_KEY = 'drengr_session_v1';

interface SessionRecord {
  session_id: string;
  started_at: number;
  last_activity_at: number;
}

function mintId(now: number): string {
  return `s-${now}-${Math.random().toString(16).slice(2, 10)}`;
}

export class SessionManager {
  private readonly storage: StorageAdapter;
  private readonly beforeRotate: () => void;
  private readonly onSessionId: (id: string) => void;
  private record: SessionRecord;
  private persistScheduled = false;

  constructor(
    storage: StorageAdapter,
    beforeRotate: () => void,
    onSessionId: (id: string) => void,
  ) {
    this.storage = storage;
    this.beforeRotate = beforeRotate;
    this.onSessionId = onSessionId;
    const now = Date.now();
    this.record = { session_id: mintId(now), started_at: now, last_activity_at: now };
  }

  currentId(): string {
    return this.record.session_id;
  }

  /** Adopt the persisted session if still fresh (works for sync and async storage). */
  async restore(): Promise<void> {
    try {
      const raw = await this.storage.getItem(SESSION_KEY);
      if (raw) {
        const p = JSON.parse(raw) as SessionRecord;
        const now = Date.now();
        if (
          p && typeof p.session_id === 'string' && p.session_id.length > 0 &&
          typeof p.started_at === 'number' && typeof p.last_activity_at === 'number' &&
          now - p.last_activity_at < SESSION_IDLE_MS &&
          now - p.started_at < SESSION_MAX_MS
        ) {
          this.record = { session_id: p.session_id, started_at: p.started_at, last_activity_at: now };
          this.onSessionId(p.session_id);
        }
      }
    } catch { /* corrupt/missing store: keep the minted session */ }
    this.schedulePersist();
  }

  /** Called on every captured event: rotate if stale, then bump activity. */
  touch(): void {
    try {
      const now = Date.now();
      if (this.stale(now)) {
        this.rotate(now);
      } else {
        this.record.last_activity_at = now;
        this.schedulePersist();
      }
    } catch { /* fail-open */ }
  }

  /** Background transition: record activity so the idle gap starts now. */
  background(): void {
    try {
      this.record.last_activity_at = Date.now();
      this.schedulePersist();
    } catch { /* fail-open */ }
  }

  /** Foreground/resume: rotate if the idle gap or max age was crossed. */
  foreground(): void {
    this.touch();
  }

  private stale(now: number): boolean {
    return (
      now - this.record.last_activity_at > SESSION_IDLE_MS ||
      now - this.record.started_at > SESSION_MAX_MS
    );
  }

  private rotate(now: number): void {
    // beforeRotate flushes the pending queue under the OLD session id.
    try { this.beforeRotate(); } catch { /* fail-open */ }
    this.record = { session_id: mintId(now), started_at: now, last_activity_at: now };
    try { this.onSessionId(this.record.session_id); } catch { /* fail-open */ }
    this.schedulePersist();
  }

  private schedulePersist(): void {
    if (this.persistScheduled) return;
    this.persistScheduled = true;
    queueMicrotask(() => {
      this.persistScheduled = false;
      try {
        void this.storage.setItem(SESSION_KEY, JSON.stringify(this.record));
      } catch { /* best-effort */ }
    });
  }
}
