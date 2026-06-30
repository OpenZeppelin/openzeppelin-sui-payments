"use client";

import { useState } from "react";

import { Button } from "@/components/ui/button";
import { googleAuthorizeUrl } from "@/lib/zklogin/oauth";
import { requestNonce } from "@/lib/zklogin/prover";
import {
  generateEphemeralKeypair,
  savePreOAuth,
} from "@/lib/zklogin/session";

const CALLBACK_PATH = "/auth/callback";

/**
 * "Log in with Google" button that kicks off the zkLogin OAuth flow.
 *
 * Only renders if `NEXT_PUBLIC_GOOGLE_CLIENT_ID` is configured. On click:
 *   1. Generate an ephemeral Ed25519 keypair (never leaves the browser).
 *   2. POST the ephemeral pubkey to `/api/zklogin-nonce`; server calls Enoki
 *      to get { nonce, randomness, maxEpoch } bound to that pubkey.
 *   3. Stash the pre-OAuth state (private key + Enoki nonce values) in
 *      sessionStorage.
 *   4. Redirect to Google with `response_type=id_token&nonce=<...>`.
 * The `/auth/callback` route picks it up when Google redirects back.
 */
export function GoogleLoginButton() {
  const clientId = process.env.NEXT_PUBLIC_GOOGLE_CLIENT_ID;
  const [busy, setBusy] = useState(false);

  const onClick = async () => {
    if (!clientId || busy) return;
    setBusy(true);
    try {
      const ephemeral = generateEphemeralKeypair();
      const ephemeralPublicKey = ephemeral.getPublicKey().toBase64();

      const { nonce, randomness, maxEpoch } = await requestNonce(ephemeralPublicKey);

      savePreOAuth({
        ephemeralPrivateKey: ephemeral.getSecretKey(),
        ephemeralPublicKey,
        randomness,
        maxEpoch,
        nonce,
      });

      const redirectUri = `${window.location.origin}${CALLBACK_PATH}`;
      window.location.href = googleAuthorizeUrl({ clientId, redirectUri, nonce });
    } catch (err) {
      setBusy(false);
      console.error("zkLogin start failed:", err);
    }
  };

  if (!clientId) return null;

  return (
    <Button onClick={onClick} disabled={busy} variant="outline" size="sm">
      {busy ? "Redirecting…" : "Log in with Google"}
    </Button>
  );
}
