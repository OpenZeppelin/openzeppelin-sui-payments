"use client";

import { useCurrentAccount } from "@mysten/dapp-kit";

import { useZkLoginSession } from "@/hooks/use-zklogin-session";

/**
 * The Sui address the app should treat as the current user, regardless of
 * how they signed in. Preference order:
 *   1. zkLogin session (custom Google flow) — takes priority so a stale wallet
 *      connection can't override a fresh Google login.
 *   2. Wallet-standard current account (dapp-kit) — Slush, Suiet, or an
 *      Enoki-registered wallet on testnet/mainnet.
 *   3. `null` — nobody's logged in.
 *
 * Prefer this over calling `useCurrentAccount()` directly anywhere identity
 * is needed for display or on-chain lookups.
 */
export function useSessionAddress(): string | null {
  const { session } = useZkLoginSession();
  const account = useCurrentAccount();
  return session?.address ?? account?.address ?? null;
}
