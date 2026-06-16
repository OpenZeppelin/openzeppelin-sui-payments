# OpenZeppelin Sui Payments — Web UI

Next.js dApp for the closed-loop stablecoin payments + loyalty + voucher template under `../contracts/`.

## Stack

- **Next.js 15** App Router + **React 19** + **TypeScript**
- **Tailwind CSS 4** + custom shadcn-style primitives in `src/components/ui/`
- **TanStack Query** for chain reads
- **`@mysten/sui`** + **`@mysten/dapp-kit`** for SuiClient and wallet wiring
- **`@mysten/enoki`** for zkLogin (OAuth → ephemeral key → zk proof) and sponsored transactions
- **`qrcode.react`** + **`@yudiel/react-qr-scanner`** for invoice/voucher QR flows

## Layout

```
app/
├── scripts/
│   └── bootstrap.ts        # publishes payments + stablecoin-mock, writes .env.local
├── src/
│   ├── app/                # Next.js App Router pages
│   │   ├── page.tsx        # role picker (Merchant / Customer)
│   │   ├── merchant/
│   │   │   ├── layout.tsx  # sidebar shell
│   │   │   ├── catalogue/
│   │   │   ├── transactions/
│   │   │   ├── balance/
│   │   │   └── redeem/
│   │   └── customer/
│   ├── components/
│   │   ├── ui/             # button, card, dialog primitives
│   │   └── providers.tsx   # QueryClient + SuiClient + dapp-kit + Enoki wallets
│   └── lib/
│       ├── sui-client.ts   # network config
│       ├── deployment.ts   # deployment IDs (from .env.local)
│       └── utils.ts        # cn, formatters
└── .env.local              # NEXT_PUBLIC_* deployment IDs + Enoki keys
```

## First-time setup

1. **Install dependencies** (pnpm preferred — repo uses workspaces):
   ```bash
   pnpm install
   ```
2. **Publish the Move packages** and have IDs written to `.env.local`:
   ```bash
   # from this directory — uses whatever your `sui client active-env` is.
   # Make sure Move.toml [environments] declares that env (devnet / testnet / mainnet).
   pnpm bootstrap
   ```
   This publishes both `contracts/payments/` and `contracts/stablecoin-mock/` and patches `app/.env.local` with `NEXT_PUBLIC_PACKAGE_ID`, `NEXT_PUBLIC_STABLECOIN_PACKAGE_ID`, etc. The Merchant object itself must be instantiated by a follow-up PTB (`merchant::create<C>(...)` consuming the `Loyalty` bundle) — see the bootstrap script output for the warning.
3. **Add your Enoki *public* API key** to `.env.local`:
   ```
   NEXT_PUBLIC_ENOKI_API_KEY=enoki_public_...
   ```
   The matching *private* key is already in place under `ENOKI_PRIVATE_API_KEY` (server-only).
4. **Add a Google OAuth client ID** in `.env.local`:
   ```
   NEXT_PUBLIC_GOOGLE_CLIENT_ID=...
   ```
   (Set up under the Enoki portal — it gets bound to the zkLogin nonce flow.)
5. **Generate + fund the sponsor keypair** for gas-free transactions:
   ```bash
   sui keytool generate ed25519 --json
   # Copy the printed `secret_key` into .env.local under SPONSOR_PRIVATE_KEY.
   # Then fund the sponsor address with testnet SUI:
   sui client faucet --address <sponsor-address>
   ```
   The /api/sponsor route uses this key to pay gas on the customer's behalf.
   Top up the sponsor address when it runs dry; chain calls will fail with a
   visible "sponsor has no SUI gas coins" error if it's empty.
6. **Run the dev server:**
   ```bash
   pnpm dev
   ```

## What's done so far (M1)

- Scaffold: Next.js project, providers, role-picker landing, placeholder pages for all merchant + customer flows.
- Tailwind 4 with custom theme variables and dark-mode media-query fallback.
- shadcn-style primitives (`button`, `card`, `dialog`) — no shadcn CLI required.
- Enoki + dapp-kit wiring under `providers.tsx`. Once the public Enoki key is set, "Login with Google" shows up as a wallet entry in dapp-kit's connect modal.
- Bootstrap script that publishes both Move packages and patches `.env.local`.

## What's next

- **M2**: Wire actual zkLogin auth (currently stubbed in providers) + sponsored-tx wrapper.
- **M3**: PTB builders for every Move entry point + typed reads for `Merchant`/`Invoice`/`Voucher`/`Receipt`.
- **M4**: Merchant Catalogue (add listing/variant + checkout drawer + Create Sale QR popup), Transactions (event-indexed), Balance.
- **M5**: Customer Pay (QR scan + confirm), Top-up (faucet route), Rewards (voucher creation), History (receipt objects).
- **M6**: Merchant Redeem (paste/scan voucher ID → confirm → burn).
- **M7**: Error states, toasts, skeletons, mobile.
