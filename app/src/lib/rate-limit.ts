import "server-only";

export interface RateLimitResult {
  ok: boolean;
  /** How long the caller should wait before retrying. Only set when `ok=false`. */
  retryAfterMs?: number;
}

/**
 * Per-key request timestamps within the sliding window. Module-scoped so
 * repeated invocations share state across route calls in the same server
 * process.
 *
 * NOT PRODUCTION-GRADE. Two limitations to be aware of:
 *
 *   - **No shared storage.** Every Next.js route worker holds its own map,
 *     so a horizontally-scaled deployment (Vercel serverless, multi-node
 *     Kubernetes) will have N independent buckets and the effective rate
 *     is `max × N`. For public deployments swap this for Redis / Vercel KV
 *     / Cloudflare KV / Upstash — the `checkAndBumpAll` signature is
 *     stable, so the swap is a body change to this file.
 *
 *   - **Attacker can spoof the bucket key.** Callers should pair the
 *     natural identity key (e.g. `sender` address) with the request's IP
 *     so an attacker who lies about `sender` still trips their own IP's
 *     bucket. See `/api/enoki-sponsor` for the pattern.
 */
const buckets = new Map<string, number[]>();
let lastCleanupAtMs = 0;
const CLEANUP_INTERVAL_MS = 5 * 60_000;

/**
 * Opportunistic map-wide sweep — called from every `checkAndBumpAll` so
 * one-off buckets (IPs / recipients hit exactly once) don't accumulate
 * forever. Uses `CLEANUP_INTERVAL_MS` as the max staleness threshold, so
 * callers must not pass `windowMs > CLEANUP_INTERVAL_MS` or their still-
 * live timestamps could get pruned. All current callers use 60s windows;
 * cap is 5 min.
 */
function maybeSweepAll(now: number): void {
  if (now - lastCleanupAtMs <= CLEANUP_INTERVAL_MS) return;
  for (const [k, times] of buckets) {
    const fresh = times.filter((t) => now - t < CLEANUP_INTERVAL_MS);
    if (fresh.length === 0) buckets.delete(k);
    else buckets.set(k, fresh);
  }
  lastCleanupAtMs = now;
}

interface Check {
  key: string;
  windowMs: number;
  max: number;
}

/**
 * Atomic multi-bucket check + bump. All buckets are peeked first; only if
 * every bucket is under its limit does the current request get recorded in
 * each. That's the important property: a request that would exceed one
 * bucket doesn't burn a token from the others.
 *
 * Use this to combine dimensions — e.g. per-sender + per-IP — so an
 * attacker rotating either dimension still trips the other's cap.
 * `retryAfterMs` is the max of the failed buckets' retry-after values.
 */
export function checkAndBumpAll(checks: Check[]): RateLimitResult {
  // Fail-fast constraint: `maybeSweepAll` prunes timestamps older than
  // `CLEANUP_INTERVAL_MS`, so a caller passing a longer window would
  // silently lose still-live buckets. Enforce here rather than in the
  // sweep itself so misuse surfaces at the call site, not five minutes
  // later.
  for (const { windowMs, key } of checks) {
    if (windowMs > CLEANUP_INTERVAL_MS) {
      throw new Error(
        `checkAndBumpAll: windowMs=${windowMs} on key="${key}" exceeds ` +
          `CLEANUP_INTERVAL_MS=${CLEANUP_INTERVAL_MS} — the map-wide sweep ` +
          `would prune still-live timestamps. Raise CLEANUP_INTERVAL_MS or ` +
          `pass a shorter window.`,
      );
    }
  }
  const now = Date.now();
  // Piggy-back the map-wide sweep on request traffic — Next.js API routes
  // can't hold background timers, so this is the only cleanup path that
  // actually runs. Bounds memory across long-lived processes for keys
  // that are hit only once (e.g. a one-off IP).
  maybeSweepAll(now);

  let worstRetry = 0;
  for (const { key, windowMs, max } of checks) {
    const history = (buckets.get(key) ?? []).filter((t) => now - t < windowMs);
    if (history.length >= max) {
      const retry = windowMs - (now - history[0]);
      if (retry > worstRetry) worstRetry = retry;
    }
  }
  if (worstRetry > 0) return { ok: false, retryAfterMs: worstRetry };
  for (const { key, windowMs } of checks) {
    const history = (buckets.get(key) ?? []).filter((t) => now - t < windowMs);
    history.push(now);
    buckets.set(key, history);
  }
  return { ok: true };
}

/**
 * Best-effort client IP for rate-limit bucket keys. Reads `x-forwarded-for`
 * then `x-real-ip` (both set by every reverse proxy of note). Falls back
 * to `"unknown"` — never throws, so the caller can trust it in a keying
 * expression.
 */
export function clientIp(req: Request): string {
  const xff = req.headers.get("x-forwarded-for");
  if (xff) {
    const first = xff.split(",")[0]?.trim();
    if (first) return first;
  }
  return req.headers.get("x-real-ip") ?? "unknown";
}

/**
 * Serialize concurrent async work by key. Two callers with the same key
 * run sequentially; different keys run in parallel. Same
 * horizontal-scaling caveat as `checkAndBumpAll` — a Vercel serverless
 * deployment gets one mutex per worker, so cross-worker races are still
 * possible. Sufficient for the local gas-station race in `/api/sponsor`
 * (two concurrent client requests picking the same deployer gas coin).
 */
const mutexes = new Map<string, Promise<unknown>>();

export async function withMutex<T>(key: string, fn: () => Promise<T>): Promise<T> {
  const prev = mutexes.get(key) ?? Promise.resolve();
  const next = prev.then(() => fn(), () => fn());
  // Two subtle requirements for the cleanup slot:
  //   1. Identity: `chain` must be the SAME reference stored in the map
  //      AND compared against inside the callback — otherwise the check
  //      can never succeed and the entry leaks.
  //   2. Rejection hygiene: if `next` rejects, using `.finally()` would
  //      propagate the rejection through `chain`, which nobody awaits →
  //      unhandled-rejection warning. `.then(cleanup, cleanup)` swallows
  //      both outcomes so `chain` always resolves cleanly.
  const cleanup = () => {
    if (mutexes.get(key) === chain) mutexes.delete(key);
  };
  const chain: Promise<void> = next.then(cleanup, cleanup);
  mutexes.set(key, chain);
  return next;
}
