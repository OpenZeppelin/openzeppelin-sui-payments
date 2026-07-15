# Enoki + Google zkLogin setup (testnet)

Step-by-step guide to enable the walletless "Continue with Google" login
option on testnet. Once wired, customers sign in with a Google account, get
a Sui address deterministically derived from their Google `sub` claim, and
their transactions are sponsored by an Enoki-backed budget - no wallet
extension, no SUI in the user's balance.

Skip this whole setup if you only need Slush / extension wallets - those
work on testnet without any Enoki configuration and pay their own gas.

## Prerequisites

- A **Google Cloud Console** project (free tier is fine).
- An account at **[portal.enoki.mystenlabs.com](https://portal.enoki.mystenlabs.com)**.
- The dApp already bootstrapped on testnet (see the root [README's Testnet
  section](../README.md#testnet)) - you'll need the payments-package
  address to configure Enoki's move-call allowlist.

Enoki does **not** work on localnet or devnet - the prover targets Sui
testnet's max-epoch window, and the mainnet variant is a separate budget.
The dApp's client-side `providers.tsx` already gates registration to
testnet/mainnet only.

## Step 1 - Google OAuth client

1. Open [Google Cloud Console](https://console.cloud.google.com/apis/credentials).
2. Pick or create a project.
3. Configure the **OAuth consent screen** if you haven't (External user
   type is fine for testing; add your dev email as a Test user so you can
   sign in without publishing the app).
4. Click **Create Credentials -> OAuth client ID -> Web application**.
5. Under **Authorized redirect URIs**, add exactly:
    - `http://localhost:3000/auth/callback` (for local dev)
    - Your deployed origin's `/auth/callback` if you have one (Vercel URL, etc.).

    The path `/auth/callback` is hardcoded in [providers.tsx](../app/src/components/providers.tsx)
    as `${window.location.origin}/auth/callback`, so the redirect URI must
    match that exact path. Adding it once here means every page a user
    might click Log in from shares the same OAuth entry - no need to list
    per-page URIs.

6. **Do NOT create a client secret.** Enoki's zkLogin flow uses the
   implicit/PKCE OAuth grant - only the client ID is needed. Copy the
   `.apps.googleusercontent.com` string for the next step.

## Step 2 - Enoki dashboard

1. Open [portal.enoki.mystenlabs.com](https://portal.enoki.mystenlabs.com)
   and sign in.
2. Create an **App** targeting **testnet**. Give it any name.
3. Under **Auth Providers -> Google**, paste the Google client ID from
   Step 1. This is what fixes the `Invalid client ID` error at proof
   generation time - without it, the prover has no way to verify Google's
   `id_token` against the zkLogin nonce.
4. Under **API Keys**, note both:
    - **Public key** (starts with `enoki_public_...`) - used client-side
      to register the walletless "Continue with Google" wallet in
      dapp-kit's connect modal.
    - **Private key** (starts with `enoki_private_...`) - used server-side
      by `/api/enoki-sponsor` and `/api/enoki-execute` to sign the
      sponsored gas leg. Never expose this to the browser.
5. Under **Sponsored Transactions -> Allowed Move Call Targets**, add
   every Move target the app issues under Enoki-sponsored txs:

    ```
    <NEXT_PUBLIC_PACKAGE_ID>::merchant::create_invoice
    <NEXT_PUBLIC_PACKAGE_ID>::merchant::pay
    <NEXT_PUBLIC_PACKAGE_ID>::merchant::pay_with_coin
    <NEXT_PUBLIC_PACKAGE_ID>::merchant::create_voucher
    <NEXT_PUBLIC_PACKAGE_ID>::merchant::redeem
    <NEXT_PUBLIC_PACKAGE_ID>::merchant::cancel_expired_invoice
    <NEXT_PUBLIC_PACKAGE_ID>::merchant::cancel_expired_voucher
    <NEXT_PUBLIC_PACKAGE_ID>::merchant::prune_invoice_receipts
    <NEXT_PUBLIC_PACKAGE_ID>::merchant::prune_voucher_receipts
    <NEXT_PUBLIC_PACKAGE_ID>::merchant::add_listing
    <NEXT_PUBLIC_PACKAGE_ID>::merchant::remove_listing
    <NEXT_PUBLIC_PACKAGE_ID>::merchant::set_listing_status
    <NEXT_PUBLIC_PACKAGE_ID>::merchant::add_listing_variant
    <NEXT_PUBLIC_PACKAGE_ID>::merchant::remove_listing_variant
    <NEXT_PUBLIC_PACKAGE_ID>::merchant::update_display
    <NEXT_PUBLIC_PACKAGE_ID>::merchant::update_config
    <NEXT_PUBLIC_OZ_ACCESS_PACKAGE_ID>::access_control::new_auth
    <NEXT_PUBLIC_PAS_PACKAGE_ID>::send_funds::request
    <NEXT_PUBLIC_PAS_PACKAGE_ID>::unlock_funds::request
    ```

    Replace each `<NEXT_PUBLIC_*>` with the corresponding id from your
    `.env.testnet`. If a call isn't on this list, `/api/enoki-sponsor`
    returns a 4xx from Enoki and the client toasts the error.

6. Under **Sponsored Transactions -> Budget**, top up SUI from Enoki's
   testnet faucet (button on the same page). This is the pool your app
   spends on user gas.

## Step 3 - Wire env vars

Populate `app/.env.testnet` (bootstrap does this automatically if you
passed `--enoki-api-key=` on `pnpm bootstrap testnet`; otherwise edit by
hand):

```bash
# Public (embedded in the JS bundle - safe to expose)
NEXT_PUBLIC_ENOKI_API_KEY=enoki_public_...
NEXT_PUBLIC_GOOGLE_CLIENT_ID=...apps.googleusercontent.com

# Server-only (never sent to the browser)
ENOKI_PRIVATE_API_KEY=enoki_private_...
```

The client-side registration happens in
[providers.tsx](../app/src/components/providers.tsx#L28-L40) - once both
public keys are set, "Continue with Google" appears in the connect modal.
The server-side sponsorship uses the private key in
[/api/enoki-sponsor](../app/src/app/api/enoki-sponsor/route.ts) and
[/api/enoki-execute](../app/src/app/api/enoki-execute/route.ts).

Copy the file to `.env.local` (bootstrap mirrors it automatically) and
restart `pnpm dev` so Next.js picks up the new env.

## Step 4 - Verify

1. Open [http://localhost:3000](http://localhost:3000) in an incognito
   window (avoids stale wallet connections).
2. Click **Log in** in the header.
3. **Continue with Google** should appear at the top of the picker (see
   `sortWallets` in [connect-button.tsx](../app/src/components/connect-button.tsx#L44)).
4. Click it, sign in with a Google account that's listed as a Test user
   in your OAuth consent screen (or any account if the app is published).
5. Approve the popup. It redirects to `/auth/callback` and closes.
6. You should now be signed in as a Sui address derived from your Google
   `sub`. The landing page auto-routes based on merchant-role check.
7. Try a sponsored action (e.g. create an invoice as the deployer, then
   pay it from the Google-signed session). Look at the Network tab -
   you should see `POST /api/enoki-sponsor -> 200`, then `POST
/api/enoki-execute -> 200`. No gas was spent from the customer's
   address.

## Troubleshooting

**`Invalid client ID` at proof generation.**
The Google client ID wasn't registered in the Enoki dashboard's Google
provider. Step 2.3.

**`404` on POST `/api/enoki-sponsor` (or 502 unknown_error).**
Enoki's own upstream is degraded. Correlated with Mysten's public testnet
fullnode outages. Wait 10-30 min, or fall back to Slush + wallet-pays
during the outage.

**`enoki-sponsor` returns 4xx with `disallowed move call target`.**
The move-call target isn't in Enoki's `allowedMoveCallTargets`. Step 2.5.
Update the dashboard and retry - the client toast reports which target
was rejected.

**Sponsored txs suddenly stop working.**
Sponsor budget is drained. Refill via the Enoki dashboard's faucet button.
See [ARCHITECTURE.md § Server-signed routes](ARCHITECTURE.md#server-signed-routes-are-throttled-not-authenticated)
for the rate limits we ship as defense-in-depth on top of Enoki's own
`allowedMoveCallTargets` + budget cap.

**`/auth/callback` renders "Signing you in..." forever.**
Google's OAuth popup couldn't post the `id_token` fragment back to the
parent. Common causes:

- Redirect URI in Google Cloud Console doesn't match
  `http://localhost:3000/auth/callback` exactly (protocol + port + path).
- Third-party cookies blocked in the browser.
- Popup blocker closed the window before the fragment posted.

**`enoki does not support NETWORK=devnet` from `/api/enoki-sponsor`.**
Enoki's zkLogin prover only supports testnet + mainnet. The client-side
`providers.tsx` gate already prevents the walletless option from
appearing on localnet / devnet; if you're seeing this error, the server
env has drifted from the client. Re-run `pnpm use testnet` or `pnpm
bootstrap testnet` to re-sync.

## Anti-abuse

The `/api/enoki-sponsor` route is public - anyone reaching it can sign
zkLogin txs with their own key and spend the app's Enoki budget on
allowed move calls. Two mitigations ship with the template:

- **Enoki-side.** `allowedMoveCallTargets` (the list you set in Step 2.5)
    - a budget cap in the dashboard. The last line of defense.
- **App-side.** Two-bucket sliding-window rate limit per (sender, IP) in
  [lib/rate-limit.ts](../app/src/lib/rate-limit.ts). Defaults 10/min per
  sender, 30/min per IP. Env-tunable via `ENOKI_SPONSOR_RATE_MAX` /
  `ENOKI_SPONSOR_IP_RATE_MAX` - see [.env.example](../app/.env.example).

Both are documented in [ARCHITECTURE.md § Server-signed routes are
throttled, not authenticated](ARCHITECTURE.md#server-signed-routes-are-throttled-not-authenticated).
The in-memory rate-limit backing does not scale horizontally - swap for
Redis / Vercel KV / Upstash before shipping a public deployment.

## Mainnet

Same shape, different Enoki App instance (Enoki's testnet and mainnet
budgets are separate). Everything above works, but bootstrap currently
refuses `mainnet` because the template's stablecoin is a freely-mintable
mock - see the root README's [Mainnet - not supported](../README.md#mainnet--not-supported)
section.

## Where to go next

- [docs/OVERVIEW.md](OVERVIEW.md) - landing page + login flow from the
  user's perspective.
- [docs/ARCHITECTURE.md § 6](ARCHITECTURE.md#6-sponsored-transactions-with-a-three-way-branch)
    - the three-way sponsorship branch (localnet / Enoki / wallet-pays)
      and where the Enoki client sits.
