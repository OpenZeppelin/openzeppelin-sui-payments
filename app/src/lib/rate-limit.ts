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
 *     / Cloudflare KV / Upstash — the `rateLimit` signature is stable, so
 *     the swap is a body change to this file.
 *
 *   - **Attacker can spoof the bucket key.** Callers should pair the
 *     natural identity key (e.g. `sender` address) with the request's IP
 *     so an attacker who lies about `sender` still trips their own IP's
 *     bucket. See `/api/enoki-sponsor` for the pattern.
 */
const buckets = new Map<string, number[]>();
let lastCleanupAtMs = 0;
const CLEANUP_INTERVAL_MS = 5 * 60_000;

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
  const now = Date.now();
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
 * Sliding-window rate limit. Returns `ok: false` when the bucket for `key`
 * has hit `max` requests within the last `windowMs`; otherwise records the
 * current request and returns `ok: true`.
 */
export function rateLimit(key: string, windowMs: number, max: number): RateLimitResult {
  const now = Date.now();

  // Opportunistic sweep — Next.js API routes can't hold background timers,
  // so we piggy-back cleanup on the first request every `CLEANUP_INTERVAL_MS`
  // to bound memory across long-lived processes.
  if (now - lastCleanupAtMs > CLEANUP_INTERVAL_MS) {
    for (const [k, times] of buckets) {
      const fresh = times.filter((t) => now - t < windowMs);
      if (fresh.length === 0) buckets.delete(k);
      else buckets.set(k, fresh);
    }
    lastCleanupAtMs = now;
  }

  const history = (buckets.get(key) ?? []).filter((t) => now - t < windowMs);
  if (history.length >= max) {
    const retryAfterMs = windowMs - (now - history[0]);
    return { ok: false, retryAfterMs };
  }
  history.push(now);
  buckets.set(key, history);
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
 * horizontal-scaling caveat as `rateLimit` — a Vercel serverless
 * deployment gets one mutex per worker, so cross-worker races are still
 * possible. Sufficient for the local gas-station race in `/api/sponsor`
 * (two concurrent client requests picking the same deployer gas coin).
 */
const mutexes = new Map<string, Promise<unknown>>();

export async function withMutex<T>(key: string, fn: () => Promise<T>): Promise<T> {
  const prev = mutexes.get(key) ?? Promise.resolve();
  const next = prev.then(() => fn(), () => fn());
  mutexes.set(
    key,
    // Whichever settle the chain reaches, clear the slot only if we're
    // still the tail of the chain — a later `withMutex` call may have
    // extended it in the meantime.
    next.finally(() => {
      if (mutexes.get(key) === next) mutexes.delete(key);
    }),
  );
  return next;
}
