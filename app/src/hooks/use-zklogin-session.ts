"use client";

import { useSyncExternalStore } from "react";

import {
  clearSession,
  loadSession,
  saveSession,
  type ZkLoginSession,
} from "@/lib/zklogin/session";

/**
 * React hook that broadcasts zkLogin session changes across the app without
 * requiring a Provider. Backed by a module-level snapshot + listener set that
 * mirrors `localStorage["zklogin:session"]`.
 *
 * `getZkLoginSessionSnapshot()` is also exposed for non-React callers (e.g.
 * `useSponsoredMutation`'s async body) that need to read the current session
 * without subscribing to React updates.
 */

type Listener = () => void;
const listeners = new Set<Listener>();
let cached: ZkLoginSession | null | undefined;

function ensureLoaded(): ZkLoginSession | null {
  if (cached === undefined) cached = loadSession();
  return cached;
}

function subscribe(cb: Listener): () => void {
  listeners.add(cb);
  return () => {
    listeners.delete(cb);
  };
}

function getSnapshot(): ZkLoginSession | null {
  return ensureLoaded();
}

function getServerSnapshot(): ZkLoginSession | null {
  return null;
}

function notify(): void {
  listeners.forEach((cb) => cb());
}

/** Non-React access — safe to call from mutation bodies + effect handlers. */
export function getZkLoginSessionSnapshot(): ZkLoginSession | null {
  return ensureLoaded();
}

export function setZkLoginSession(session: ZkLoginSession | null): void {
  if (session) saveSession(session);
  else clearSession();
  cached = session;
  notify();
}

export function useZkLoginSession() {
  const session = useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot);
  return {
    session,
    isActive: session != null,
    setSession: setZkLoginSession,
    logout: () => setZkLoginSession(null),
  };
}
