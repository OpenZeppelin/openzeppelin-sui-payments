"use client";

/**
 * Client-side wrappers for our zkLogin API proxy routes.
 *
 * We proxy through `/api/zklogin-nonce` and `/api/zklogin-prove` rather than
 * calling Mysten's public prover directly, because the public prover only
 * accepts a hard-coded list of OAuth `aud` values. Enoki's server-side
 * proving accepts any Google OAuth client_id that's registered in the Enoki
 * dashboard, so we forward there.
 */

import type { ProofInputs } from "@/lib/zklogin/session";

export interface NonceResponse {
  nonce: string;
  randomness: string;
  maxEpoch: number;
}

export interface ProveResponse {
  proofPoints: ProofInputs["proofPoints"];
  headerBase64: string;
  issBase64Details: ProofInputs["issBase64Details"];
  addressSeed: string;
  salt: string;
  address: string;
}

export async function requestNonce(ephemeralPublicKey: string): Promise<NonceResponse> {
  const resp = await fetch("/api/zklogin-nonce", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ephemeralPublicKey }),
  });
  if (!resp.ok) {
    const err = (await resp.json().catch(() => null)) as { error?: string } | null;
    throw new Error(err?.error ?? `zklogin-nonce failed (${resp.status})`);
  }
  return (await resp.json()) as NonceResponse;
}

export async function requestProof(args: {
  jwt: string;
  ephemeralPublicKey: string;
  maxEpoch: number;
  randomness: string;
}): Promise<ProveResponse> {
  const resp = await fetch("/api/zklogin-prove", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  if (!resp.ok) {
    const err = (await resp.json().catch(() => null)) as { error?: string } | null;
    throw new Error(err?.error ?? `zklogin-prove failed (${resp.status})`);
  }
  return (await resp.json()) as ProveResponse;
}
