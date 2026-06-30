"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";

import { setZkLoginSession } from "@/hooks/use-zklogin-session";
import { parseIdTokenFromHash } from "@/lib/zklogin/oauth";
import { requestProof } from "@/lib/zklogin/prover";
import { popPreOAuth } from "@/lib/zklogin/session";

/**
 * Landing page for the Google OAuth redirect. Google sends
 *   /auth/callback#id_token=<jwt>&state=…
 * We pull the JWT out of the fragment, combine it with the pre-OAuth state
 * we stashed before the redirect, POST to `/api/zklogin-prove` (which forwards
 * to Enoki), then materialize the full zkLoginSession and bounce back to `/`.
 */
export default function AuthCallbackPage() {
  const router = useRouter();
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      try {
        const jwt = parseIdTokenFromHash(window.location.hash);
        if (!jwt) throw new Error("no id_token in redirect fragment");

        const pre = popPreOAuth();
        if (!pre) {
          throw new Error(
            "no pre-OAuth state found — the session was cleared before the redirect completed",
          );
        }

        const result = await requestProof({
          jwt,
          ephemeralPublicKey: pre.ephemeralPublicKey,
          maxEpoch: pre.maxEpoch,
          randomness: pre.randomness,
        });

        setZkLoginSession({
          address: result.address,
          ephemeralPrivateKey: pre.ephemeralPrivateKey,
          maxEpoch: pre.maxEpoch,
          proof: {
            proofPoints: result.proofPoints,
            issBase64Details: result.issBase64Details,
            headerBase64: result.headerBase64,
          },
          jwt,
          addressSeed: result.addressSeed,
        });

        router.replace("/");
      } catch (err) {
        setError(err instanceof Error ? err.message : String(err));
      }
    })();
  }, [router]);

  if (error) {
    return (
      <div className="p-8">
        <h1 className="text-xl font-semibold">Sign-in failed</h1>
        <p className="mt-2 text-sm text-[color:var(--color-muted-foreground)]">
          {error}
        </p>
      </div>
    );
  }
  return (
    <div className="p-8">
      <h1 className="text-xl font-semibold">Signing you in…</h1>
      <p className="mt-2 text-sm text-[color:var(--color-muted-foreground)]">
        Fetching your zkLogin proof from Enoki.
      </p>
    </div>
  );
}
