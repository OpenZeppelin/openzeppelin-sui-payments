/**
 * Landing route for Google OAuth redirects triggered by the Enoki-registered
 * "Sign in with Google" wallet in dapp-kit's connect modal. Enoki opens the
 * OAuth flow in a popup, and the parent window polls `popup.location.hash`
 * for the `id_token=…` fragment — it detects completion, calls the wallet's
 * internal `handleAuthCallback`, then closes the popup. All the popup needs
 * to do is load a page at `<origin>/auth/callback` so `window.location.hash`
 * populates. There is no application-side logic to run here.
 *
 * This URL must match the `redirectUrl` in `registerEnokiWallets` (see
 * `providers.tsx`) and be in Google Cloud Console's Authorized redirect URIs
 * for the OAuth client.
 */
export default function AuthCallbackPage() {
  return (
    <div className="p-8">
      <h1 className="text-xl font-semibold">Signing you in…</h1>
      <p className="mt-2 text-sm text-[color:var(--color-muted-foreground)]">
        This window closes automatically.
      </p>
    </div>
  );
}
