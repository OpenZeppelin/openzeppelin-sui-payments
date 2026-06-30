"use client";

/**
 * Google OAuth 2.0 implicit-flow helpers for zkLogin.
 *
 * Uses `response_type=id_token` so Google returns the JWT directly in the URL
 * fragment (no code exchange, no client_secret needed). The `nonce` param
 * carries our zkLogin commitment — Google echoes it back inside the signed
 * JWT, which is what proves to the on-chain zkLogin verifier that the JWT
 * matches the ephemeral pubkey we're about to sign with.
 */

export interface OAuthConfig {
  clientId: string;
  redirectUri: string;
  nonce: string;
}

export function googleAuthorizeUrl(cfg: OAuthConfig): string {
  const params = new URLSearchParams({
    client_id: cfg.clientId,
    response_type: "id_token",
    redirect_uri: cfg.redirectUri,
    scope: "openid email",
    nonce: cfg.nonce,
  });
  return `https://accounts.google.com/o/oauth2/v2/auth?${params.toString()}`;
}

/** Parse `#id_token=…&state=…` fragment on the callback page. */
export function parseIdTokenFromHash(hash: string): string | null {
  const trimmed = hash.startsWith("#") ? hash.slice(1) : hash;
  const params = new URLSearchParams(trimmed);
  return params.get("id_token");
}
