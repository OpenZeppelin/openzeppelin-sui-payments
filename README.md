# openzeppelin-sui-payments

Closed-loop **stablecoin payments + loyalty + redemption** template for Sui, built on
the [Permissioned Asset Standard (PAS)](https://github.com/MystenLabs/pas) with role-based
access control from [openzeppelin/contracts-sui](https://github.com/OpenZeppelin/contracts-sui).

## Overview

A merchant deploys this template to accept stablecoin payments, automatically mint a
soulbound loyalty currency (`LOYALTY`) on each settlement, and let customers redeem that
loyalty for goods later - all on-chain, with PAS handling the balance/policy layer.

Two settlement flows, mirroring real-world POS. The `Merchant` shared object is the hub:
it stores open invoices, open vouchers, and settlement receipts in tables and owns both
flows.

- **Invoice -> Pay** - merchant issues an invoice via `merchant::create_invoice` (role-gated on `CashierRole`)
  carrying line items and the snapshotted loyalty reward; it's stored in the `Merchant` and
  surfaced by ID (off-chain QR). Customer scans, sends stablecoin via PAS through
  `merchant::pay`, earns LOYALTY balance, and a `Receipt` is recorded in the `Merchant`.
  For open-loop settlement with a plain (non-PAS) `Coin<C>`, `merchant::pay_with_coin`
  transfers the coin directly to the payout address; same loyalty + receipt outcome.
- **Voucher -> Redeem** - customer locks LOYALTY balance in a voucher via
  `merchant::create_voucher` (stored in the `Merchant`, surfaced by ID for the QR);
  merchant scans + `merchant::redeem`s, the balance burns, and a `Receipt` is recorded.

Both invoices and vouchers carry the same `Item` type (variant_id + quantity + snapshot
unit_price), so the on-chain accounting is symmetric. Receipts use a generic `Receipt<T>`
with a flow-specific payload - `Receipt<Payment>` and `Receipt<Redemption>` - stored in the
`Merchant` in separate `invoice_receipts` / `voucher_receipts` tables keyed by the settling
invoice/voucher ID; per-customer history is served off-chain from the `InvoicePaid` /
`VoucherRedeemed` event stream.

Access control uses a single `AccessControl<MERCHANT>` registry with three operational
roles:

- **`MerchantRole`** - payout address, mint config, display name
- **`CatalogManagerRole`** - listings + variants CRUD + active toggle
- **`CashierRole`** - invoice issuance + voucher redemption

The deployer is the root holder and grants operational roles separately, so
cold-storage admin keys stay out of daily POS operations.

![OpenZeppelin Sui Payments - merchant catalogue: cart summary at top, per-listing cards (Espresso, Black coffee, Matcha, Chai latte) with per-variant Add buttons, order-ref field, and Create invoice CTA that mints an on-chain `Invoice` under `CashierRole`](docs/images/merchant_catalogue.png)

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) - Smart-contract design: PAS
  custody, dual settlement flows on one `Merchant`, hashlock voucher model,
  access-control roles, on-chain-Clock expiry, and the three-way sponsored-
  tx branch - plus the PTB-flow Mermaid diagram mapping every UI action to
  its on-chain Move call.
- [docs/OVERVIEW.md](docs/OVERVIEW.md) - Landing page, role-based auto-
  routing, and the Google / Slush login options.
- [docs/OVERVIEW_CUSTOMER.md](docs/OVERVIEW_CUSTOMER.md) - Customer-side
  pages: dashboard, top up, scan to pay, rewards, history.
- [docs/OVERVIEW_MERCHANT.md](docs/OVERVIEW_MERCHANT.md) - Merchant-side
  pages: catalogue + invoicing, redeem, transactions, settings, balance.

## Repository Layout

```text
contracts/
├── payments/         # The template (8 modules + 5 test suites + 2 test helpers)
└── stablecoin-mock/  # Testnet/local-only mock PAS stablecoin (for end-to-end tests)
app/                  # Next.js dApp - reads deployment ids from `.env.local`
├── src/              # Pages, hooks, PTB builders, API routes
└── scripts/          # bootstrap.ts (publish + wire), seed.ts (catalog), use.ts (env swap)
```

Both Move packages resolve `@pas/pas` and `@openzeppelin-move/*` via MVR - no
vendored deps. On testnet/mainnet the CLI resolves them to already-published
canonical addresses; on localnet the tooling test-publishes the deps
alongside the payments package with `--publish-unpublished-deps`.

## Prerequisites

- **Sui CLI ≥ 1.74.1** (matches CI). The contracts use `sui::coin_registry`,
  which was added in 1.74; older CLIs won't build. Recent versions bundle
  `sui start` for the local network.
- **[MVR CLI](https://docs.mvr.app)** - `mvr resolve` is used to find
  `@pas/pas` and OpenZeppelin Move packages on testnet/mainnet.
- **pnpm** and **Node 20+** - the app is a Next.js 15 project.
- **Google OAuth client id** (only if you want the Enoki-registered
  Google login option - Slush works without it). Register at Google
  Cloud Console -> Web application, then paste it into Enoki's dashboard
  and expose it as `NEXT_PUBLIC_GOOGLE_CLIENT_ID`.

## Quickstart (localnet)

```bash
# 1. Clone and install
git clone git@github.com:OpenZeppelin/openzeppelin-sui-payments.git
cd openzeppelin-sui-payments/app
pnpm install

# 2. Start localnet in a separate terminal. Keep this process running.
sui start --with-faucet --force-regenesis

# 3. Register the localnet as a Sui CLI env alias (one-time per machine).
sui client new-env --alias localnet --rpc http://127.0.0.1:9000
sui client switch --env localnet

# 4. Generate a fresh ed25519 deployer address. This adds it to the CLI
#    keystore and makes it the active address; faucet-fund it so
#    `sui client publish` has gas.
sui client new-address ed25519 deployer
sui client switch --address deployer
sui client faucet

# 5. Export the deployer private key. It's a bech32 `suiprivkey1...` string.
#    You'll paste it into bootstrap below, AND - since the deployer holds
#    all three merchant roles after bootstrap - you can import the same
#    key into Slush (Slush -> Import Wallet -> Private Key) to sign as the
#    deployer in the browser at http://localhost:3000 and land straight on
#    /merchant/catalogue.
# sui keytool export --key-identity deployer

# 6. Bootstrap. Test-publishes @pas/pas + openzeppelin_access alongside
#    payments + stablecoin-mock, creates the shared `Merchant` +
#    `AccessControl<MERCHANT>` + PAS namespaces, grants the deployer all
#    three operational roles, creates the payout PAS account, and writes
#    every id + address to `.env.localnet` (mirrored to `.env.local` for
#    the Next.js dev server).
pnpm bootstrap localnet --deployer-key="<paste the suiprivkey1... from step 5>"

# 7. Seed the catalog. Idempotent by refusal - aborts if the catalog
#    already has entries; delete them from the /merchant/catalogue UI or
#    re-run against a fresh chain to re-seed.
pnpm seed

# 8. Start the dApp and open http://localhost:3000.
pnpm dev
```

In the browser:

- Landing page runs a role check against the connected wallet; the
  deployer holds all three roles after bootstrap, so it auto-routes to
  `/merchant/catalogue`. Log out and connect a fresh wallet to see the
  `/customer` side.
- On localnet, Google-via-Enoki won't work (Enoki's prover targets Sui
  testnet's max-epoch window). Use Slush or another extension wallet -
  the localnet gas station sponsors non-deployer txs so the connected
  wallet doesn't need SUI.

## Testnet

Same script, one extra flag:

```bash
sui client switch --env testnet
sui client faucet
pnpm bootstrap testnet \
  --deployer-key=suiprivkey1... \
  --enoki-api-key=enoki_private_...
```

`--deployer-key` and `--enoki-api-key` are only persisted to
`.env.testnet` when supplied - the default is "no server-side secrets on
shared chains." For the Enoki-registered "Continue with Google" wallet
to work, see the step-by-step [docs/SETUP_ENOKI.md](docs/SETUP_ENOKI.md)
guide - it covers the Google Cloud Console OAuth client, the Enoki
dashboard configuration (Google provider, allowed move-call targets,
budget), env-var wiring, and troubleshooting the specific errors we've
hit. Slush + other extension wallets work without any Enoki setup.

## Mainnet — not supported

`pnpm bootstrap mainnet` is deliberately refused. This template publishes
`contracts/stablecoin-mock` and wires it in as the merchant's accepted
payment type — the mock is freely mintable via `stablecoin_mock::faucet`
and freely transferable, which would make any real invoice settled in
this currency worthless. Bootstrap throws with a pointed error rather
than silently deploying that on mainnet.

Shipping to mainnet means swapping in a real PAS-issued stablecoin
(matching how `payment::pay<C>` is generic over the payment currency).
That integration path isn't yet in the template.

## Switching between networks

`.env.<network>` is the per-network source of truth; `.env.local` is a
mirror of whichever is currently active. To swap:

```bash
pnpm use localnet   # copies .env.localnet -> .env.local
pnpm use testnet    # copies .env.testnet  -> .env.local
```

Restart `pnpm dev` afterward so Next.js picks up the new env.

## Troubleshooting

- **`sui client has no env alias matching localnet`** - bootstrap couldn't
  find a Sui CLI env for the target network. Add one:
  `sui client new-env --alias localnet --rpc http://127.0.0.1:9000`.
- **`Insufficient gas` / `no gas coin`** during bootstrap - the active
  address is unfunded. Run `sui client faucet` (localnet unlimited;
  testnet subject to rate limit).
- **Fresh voucher / invoice shows as expired in the UI** - the wallclock
  and on-chain `Clock` at `0x6` have drifted. Localnet clock advances
  only on checkpoints and can lag by minutes if the node was paused;
  the UI already reads the on-chain clock, so a hard refresh + a few
  seconds of chain activity fixes it. See
  [docs/ARCHITECTURE.md § 5](docs/ARCHITECTURE.md#5-time-comes-from-the-on-chain-clock-not-the-wallclock).
- **`Unexpected status code: 404` on testnet** - Mysten's public
  `fullnode.testnet.sui.io` is down or degraded. Override the RPC
  without re-bootstrapping:
  `NEXT_PUBLIC_SUI_RPC_URL=https://sui-testnet-rpc.publicnode.com` in
  `.env.local`, restart `pnpm dev`. Suiscan and Blockvision also
  publish testnet RPCs.
- **Enoki `502 unknown_error`** - Enoki's execution backend is
  intermittently unavailable. Correlates with Mysten's testnet fullnode
  outages. Slush signs its own txs and works when Enoki doesn't.
- **`SPONSOR_PRIVATE_KEY` still in an old `.env.local`** - leftover from
  a pre-refactor bootstrap. Inert now; the app doesn't read it. Delete
  the line to tidy up.

## Security

This project is maintained by OpenZeppelin with the goal of providing a secure and
reliable starter dApp for PoS systems built on top of the Sui ecosystem.

Refer to [SECURITY.md](SECURITY.md) for more details.

Past audits can be found in [`audits/`](./audits).
