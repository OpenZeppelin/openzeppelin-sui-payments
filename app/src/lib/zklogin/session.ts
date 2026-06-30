"use client";

/**
 * Client-side zkLogin session store.
 *
 * The session is what a "Log in with Google" user has instead of a wallet
 * extension: an ephemeral keypair the client holds locally, plus a ZK proof
 * from Enoki (via our `/api/zklogin-prove` proxy) that binds that keypair to
 * the user's Sui address. Every transaction they submit is signed by the
 * ephemeral key and wrapped in a zkLoginSignature — no wallet UI ever pops up.
 *
 * Persistence layout:
 *   - `sessionStorage["zklogin:pre-oauth"]` — populated before we redirect to
 *     Google (ephemeral key + Enoki-issued randomness + nonce + maxEpoch). The
 *     callback page pops it to reconstruct the session; if the tab is closed
 *     mid-flow it's lost and the user re-authenticates.
 *   - `localStorage["zklogin:session"]` — populated after the prover returns.
 *     Survives reloads and browser restarts up to `maxEpoch`.
 *
 * Salt is managed by Enoki (keyed by JWT `sub`) — we only see the derived
 * `addressSeed` and final address. This means the same Google account gets
 * the same Sui address across devices.
 */

import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";

const STORAGE_KEY_PRE_OAUTH = "zklogin:pre-oauth";
const STORAGE_KEY_SESSION = "zklogin:session";

/** State stashed pre-OAuth-redirect. Popped by the callback page. */
export interface PreOAuthState {
  ephemeralPrivateKey: string;
  ephemeralPublicKey: string;
  randomness: string;
  maxEpoch: number;
  nonce: string;
}

/** ZK proof + JWT metadata returned by Enoki's ZKP endpoint. Shape matches
 *  `getZkLoginSignature`'s expected `inputs`, minus `addressSeed` which is
 *  stored alongside on the session for convenience. */
export interface ProofInputs {
  proofPoints: { a: string[]; b: string[][]; c: string[] };
  issBase64Details: { value: string; indexMod4: number };
  headerBase64: string;
}

export interface ZkLoginSession {
  /** Sui address the user signs as (derived from JWT + Enoki-managed salt). */
  address: string;
  /** Ephemeral Ed25519 private key (bech32 `suiprivkey…`). */
  ephemeralPrivateKey: string;
  /** Latest epoch at which the proof remains valid. Bounds session lifetime. */
  maxEpoch: number;
  /** ZK proof from Enoki. */
  proof: ProofInputs;
  /** Raw JWT — kept for debugging / potential re-proving. */
  jwt: string;
  /** `genAddressSeed(salt, "sub", sub, aud)` as a decimal string. */
  addressSeed: string;
}

export function savePreOAuth(state: PreOAuthState): void {
  if (typeof window === "undefined") return;
  window.sessionStorage.setItem(STORAGE_KEY_PRE_OAUTH, JSON.stringify(state));
}

/** Read + consume pre-OAuth state. Removed from storage as a side effect so
 *  a stale value can't come back to bite a later, unrelated login attempt. */
export function popPreOAuth(): PreOAuthState | null {
  if (typeof window === "undefined") return null;
  const raw = window.sessionStorage.getItem(STORAGE_KEY_PRE_OAUTH);
  if (!raw) return null;
  window.sessionStorage.removeItem(STORAGE_KEY_PRE_OAUTH);
  try {
    return JSON.parse(raw) as PreOAuthState;
  } catch {
    return null;
  }
}

export function saveSession(session: ZkLoginSession): void {
  if (typeof window === "undefined") return;
  window.localStorage.setItem(STORAGE_KEY_SESSION, JSON.stringify(session));
}

export function loadSession(): ZkLoginSession | null {
  if (typeof window === "undefined") return null;
  const raw = window.localStorage.getItem(STORAGE_KEY_SESSION);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as ZkLoginSession;
  } catch {
    return null;
  }
}

export function clearSession(): void {
  if (typeof window === "undefined") return;
  window.localStorage.removeItem(STORAGE_KEY_SESSION);
}

/** Fresh ephemeral keypair for a new session. */
export function generateEphemeralKeypair(): Ed25519Keypair {
  return new Ed25519Keypair();
}

/** Rehydrate a keypair from its bech32 private key. */
export function ephemeralFromSecret(privateKey: string): Ed25519Keypair {
  return Ed25519Keypair.fromSecretKey(privateKey);
}
