# OpenZeppelin Sui Payments - Web UI

Next.js dApp for the closed-loop stablecoin payments + loyalty + voucher template under `../contracts/`.

## Stack

- **Next.js 15** App Router + **React 19** + **TypeScript**
- **Tailwind CSS 4** + custom shadcn-style primitives in `src/components/ui/`
- **TanStack Query** for chain reads
- **`@mysten/sui`** + **`@mysten/dapp-kit`** for SuiClient and wallet wiring
- **`@mysten/enoki`** for zkLogin (OAuth -> ephemeral key -> zk proof) and sponsored transactions
- **`qrcode.react`** + **`@yudiel/react-qr-scanner`** for invoice/voucher QR flows

## Layout

```
app/
├── scripts/
│   ├── bootstrap.ts        # publishes payments + stablecoin-mock; writes .env.<network>
│   ├── seed.ts             # seeds catalog with a demo menu (idempotent by refusal)
│   └── use.ts              # copies .env.<network> -> .env.local for the dev server
├── src/
│   ├── app/                # Next.js App Router pages
│   │   ├── page.tsx        # landing: role-based auto-route on wallet connect
│   │   ├── error.tsx       # root error boundary (catches landing-page throws)
│   │   ├── auth/callback/  # Enoki OAuth popup lands here (parent detects hash)
│   │   ├── api/            # /sponsor (localnet) + /enoki-sponsor + /enoki-execute + /topup
│   │   ├── merchant/       # catalogue, transactions, balance, redeem, settings
│   │   │   └── error.tsx   # segment error boundary (sidebar stays intact)
│   │   └── customer/       # dashboard, pay, rewards, topup, history
│   │       └── error.tsx   # segment error boundary (header stays intact)
│   ├── components/
│   │   ├── ui/             # button, card, dialog primitives (shadcn-style)
│   │   ├── customer/       # voucher-status-dialog
│   │   ├── merchant/       # invoice-status-dialog, add-listing + add-variant dialogs
│   │   ├── shared/         # qr-display, qr-scanner, error-fallback
│   │   ├── connect-button.tsx    # custom wallet picker (Enoki-first ordering)
│   │   └── providers.tsx         # QueryClient + SuiClient + dapp-kit + Enoki
│   ├── hooks/              # queries, use-sponsored-mutation, use-sui-clock,
│   │                       # use-pas-account, use-has-merchant-role, use-variant-lookup
│   ├── lib/
│   │   ├── move/           # PTB builders (auth, listing, merchant, pas, payment,
│   │   │                   # redemption, stablecoin) + types.ts parsers
│   │   ├── sui-client.ts   # network + optional NEXT_PUBLIC_SUI_RPC_URL override
│   │   ├── deployment.ts   # deployment IDs read lazily from .env.local
│   │   ├── deployer-server.ts    # server-only deployer keypair (topup + sponsor)
│   │   ├── enoki-server.ts # server-only EnokiClient
│   │   ├── rate-limit.ts   # server-only two-bucket limiter + mutex (see .env.example)
│   │   ├── preimage.ts     # blake2b256 + helpers for the voucher hashlock
│   │   ├── qr.ts           # invoice / voucher QR encode + decode
│   │   └── utils.ts        # cn, formatAmount, formatItems, shortAddr
│   └── types/              # ambient .d.ts (CSS side-effect import)
└── .env.<network>          # NEXT_PUBLIC_* deployment IDs + secret keys (gitignored);
                            # .env.local is a mirror of the active one
```

## First-time setup

1. **Install dependencies** (pnpm preferred - repo uses workspaces):
   ```bash
   pnpm install
   ```
2. **Publish the Move packages** and have IDs written to `.env.<network>`
   (mirrored to `.env.local` for the Next.js dev server). `bootstrap.ts`
   requires `--deployer-key=<suiprivkey1...>` on every network; the
   derived address must match `sui client active-address` because
   `sui client publish` signs the initial publish tx with the CLI's
   active key. Publish strategy is picked from the network arg:

   ```bash
   # Option A - testnet (pas + openzeppelin_access are already on chain).
   # Bootstrap resolves them via `mvr resolve` and runs `sui client publish`
   # for payments + stablecoin-mock. Mainnet is deliberately refused - see
   # the root README's "Mainnet — not supported" section.
   sui client switch --env testnet
   sui client faucet
   pnpm bootstrap testnet \
     --deployer-key=suiprivkey1... \
     --enoki-api-key=enoki_private_...   # optional; enables Enoki sponsorship

   # Option B - localnet (everything starts empty). Bootstrap runs
   # `sui client test-publish --publish-unpublished-deps` to republish pas
   # + openzeppelin_access onto the fresh chain alongside payments +
   # stablecoin-mock, recording addresses in `Pubfile.local.toml`
   # (gitignored). See the root README's Quickstart for the fresh
   # `sui client new-address ed25519 deployer` + faucet flow.
   sui start --with-faucet --force-regenesis     # in another terminal
   sui client switch --env localnet
   pnpm bootstrap localnet --deployer-key=suiprivkey1...
   ```

   In either mode, `bootstrap.ts`:
   - resolves (or freshly publishes) pas + its Namespace,
   - publishes `contracts/payments/` and `contracts/stablecoin-mock/`,
   - runs one PTB to wire up the stablecoin policy, mint the loyalty
     bundle, create + share a Merchant, and grant the deployer all three
     operational roles (on localnet it also prepends
     `pas::namespace::setup` to link the fresh Namespace to its UpgradeCap),
   - creates the payout PAS account,
   - writes every `NEXT_PUBLIC_*` id to `.env.<network>` (mode 0o600,
     temp+rename atomic) and mirrors it to `.env.local`.

   When re-bootstrapping localnet after `--force-regenesis`, the stale
   `Pubfile.local.toml` files are cleared automatically.
3. **Add your Enoki *public* API key** to `.env.local`:
   ```
   NEXT_PUBLIC_ENOKI_API_KEY=enoki_public_...
   ```
   Add the matching *private* key under `ENOKI_PRIVATE_API_KEY` (server-only) - it ships empty in `.env.example` and is only populated when you pass `--enoki-api-key=...` to `pnpm bootstrap`.
4. **Add a Google OAuth client ID** in `.env.local`:
   ```
   NEXT_PUBLIC_GOOGLE_CLIENT_ID=...
   ```
   (Set up under the Enoki portal - it gets bound to the zkLogin nonce flow.)
5. **Run the dev server:**
   ```bash
   pnpm dev
   ```
