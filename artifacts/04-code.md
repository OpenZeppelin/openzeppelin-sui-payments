---
stage: code
project: openzeppelin-sui-payments
mode: greenfield
extends: null
status: draft
timestamp: 2026-05-28
author: Alisander Qoshqosh
previous_stage: artifacts/01-research.md
tags: [pas, payments, loyalty, soulbound, qr-payments, design-merged]
---

# OpenZeppelin Sui Payments — Code Draft (with merged design + invariants notes)

## Summary

Six Move modules implementing a closed-loop PAS-stablecoin payment + soulbound PAS-loyalty + voucher-based redemption template on Sui. The workflow is symmetric across both asset sides — merchant issues an on-chain intent (`Invoice` for payment, `RedemptionVoucher` for redemption), customer scans the intent's object ID from a QR, and the customer's PTB settles atomically: stablecoin moves merchant-ward (or loyalty burns), loyalty rewards mint (on payment only), the intent object is destroyed, and a settlement event fires. Build clean against the testnet Sui framework and a vendored copy of `MystenLabs/pas @ b64f0c5`. **No `02-design.md` or `03-invariants.md` were produced separately** — design decisions and invariants are merged into this document at the dev's request. Pipeline therefore: research (01) → code (this document, 04).

## Modules

| Module | Lines | Status | Purpose |
|---|---|---|---|
| `payments::events` | 70 | Draft | `InvoicePaid`, `VoucherRedeemed` event structs + pkg-private `emit_*` helpers |
| `payments::invoice` | 95 | Draft | `Invoice` struct + `share` / `cancel` / accessors + pkg `new`/`destroy` (issuance + settlement live in `merchant`) |
| `payments::listing` | 60 | Draft | Pure data type — `Listing` struct + pkg-private constructors/setters + public accessors |
| `payments::loyalty` | 129 | Draft | LOYALTY OTW + `Loyalty` bundle + `RedeemUnlockApproval` witness + PAS Policy setup + pkg-private `mint_into` |
| `payments::merchant` | 323 | Draft | `Merchant` shared state + `MerchantCap` + `create`/`share` + cap-gated mutators + listing CRUD + `issue_invoice` (admin) + `pay<S>` |
| `payments::redemption` | 144 | Draft | `RedemptionVoucher` + `create_voucher` (admin) / `share_voucher` / `redeem` / `cancel_voucher` |
| `stablecoin_mock::stablecoin_mock` | 92 | Draft | PAS-managed mock stablecoin + permissive `TransferApproval` + faucet |
| **total** | **913** | | |

## Design Context (merged from skipped `02-design.md`)

### Repository layout

```
.
├── artifacts/                              # stage artifacts (this is 04-code.md)
├── vendor/pas/                             # vendored MystenLabs/pas @ b64f0c5,
│                                            with [environments] test-publish added
└── packages/dapp/contracts/
    ├── payments/                           # main Move package (depends on vendored PAS)
    │   ├── Move.toml                       (edition "2024", local dep on vendor/pas)
    │   └── sources/{merchant,listing,loyalty,invoice,redemption,events}.move
    └── stablecoin-mock/                    # peer package — PAS-managed Mock USD
        ├── Move.toml
        └── sources/stablecoin_mock.move
```

### Key design decisions

1. **No `access` module / shim.** Sui-native capability pattern: every gated entry takes `&MerchantCap`, validated via `merchant::assert_cap_matches`. Migration to OZ AccessControl when available is a future stage.
2. **Single shared `Merchant` object** holds *everything* per-merchant: identity, payout, loyalty caps + policy IDs, mint policy params, and listings `Table<u64, Listing>`. No separate `Catalog`.
3. **`merchant.move` owns the Merchant state, listing CRUD, invoice issuance, and customer-side payment settlement.** Invoice issuance (`issue_invoice`) and customer settlement (`pay`) both live here because they mutate `Merchant` and need `&Merchant`/`&MerchantCap` — putting them in `invoice.move` would create a module dependency cycle. `invoice.move` is therefore reduced to: the `Invoice` struct + lifecycle helpers (`share`, `cancel`, pkg `new`/`destroy`) + read accessors. Redemption is fully self-contained in `redemption.move`.
4. **Two-tx onboarding (forced by Sui Move init constraints).** Publish runs `loyalty::init` which creates only the Sui coin + freezes metadata; the deployer's second tx is a PTB calling `loyalty::setup(&mut namespace, treasury_cap)` then `merchant::create(loyalty, …)` then `merchant::share(merchant)`.
5. **PAS Namespace is global** (singleton per PAS publish), not per-merchant. So `Merchant` does NOT carry a `loyalty_namespace_id` field. Functions needing namespace take `&mut Namespace` as a separate shared input.
6. **Mint policy params are immutable** post-`create`. No runtime mutator.
7. **PolicyCap is held inside `Merchant`** for future controlled policy migration, but **no runtime adjustment entry is exposed in v1**. Soulbound is permanent.
8. **Symmetric intent-object workflow for both payment and redemption.** Merchant issues an `Invoice` (payment) or `RedemptionVoucher` (redemption); customer scans the object ID from a QR and settles via `pay<S>` / `redeem`; settlement consumes the intent + emits an event. Permissionless `cancel_*` after expiry destroys unused intents. **Customer balance is never locked between issuance and settlement** — it stays in the customer's PAS Account until they actively settle. If they walk away, the intent just expires.
9. **Loyalty asset is a standard Sui Coin (decimals 0)** wrapped with `Policy<Balance<LOYALTY>>` that registers approvals only for `unlock_funds` — `send_funds` and `clawback_funds` have no approvals → soulbound, no clawback.
10. **Stablecoin is PAS-managed.** Customer's stablecoin lives in their PAS `Account<S>`; payment moves it via `send_funds` (gated by the stablecoin issuer's `Policy<Balance<S>>` and its own `TransferApproval` witness). Generic over `S` so forks can plug in real PAS-issued stablecoins (e.g. S3 / S3.MONEY) without Move-side changes. The mock package `stablecoin_mock` ships a devnet `STABLECOIN_MOCK` with a permissive `TransferApproval` and a faucet.
11. **Mint happens inline in `payment::pay`.** Stablecoin transfer (`send_funds::resolve_balance`) and loyalty mint (`loyalty::mint_into`) are bundled in one customer-PTB call. Atomic. Mint rate from `Merchant.mint_*` fields, capped at `max_mint_per_payment`.
12. **Lazy PAS Account creation** for both customer's `Account<LOYALTY>` and merchant's / customer's `Account<S>` — frontend's PTB prepends `account::create_and_share(&mut namespace, addr)` calls if the accounts don't yet exist. Permissionless in PAS.
13. **No on-chain code/hash on the redemption side.** `redeem` is gated solely by the merchant cap (via `create_voucher`) and the customer's PAS auth (on the unlock request). Merchant trust + customer presence is the explicit security boundary. (Earlier design used a sha3-256 code commitment but it was security theater for short codes; dropped.)

### Public API surface

| Module | Function | Visibility | Purpose |
|---|---|---|---|
| loyalty | `init(otw, ctx)` | private (auto-called) | Create currency + freeze metadata |
| loyalty | `setup(namespace, cap, ctx) -> Loyalty` | public | Create Policy, register approvals, bundle outputs |
| loyalty | `destruct(loyalty) -> (TreasuryCap, PolicyCap, ID)` | pkg | Consumed by `merchant::create` |
| loyalty | `mint_into(cap, account, amount)` | pkg | Called by `payment::pay` |
| loyalty | `new_redeem_unlock_approval() -> RedeemUnlockApproval` | pkg | Called by `redemption::redeem` |
| merchant | `create(loyalty, …) -> (Merchant, MerchantCap)` | public | Consume Loyalty; return Merchant + cap |
| merchant | `share(merchant)` | public | Share the Merchant (`key`-only) |
| merchant | `name`, `logo_url`, `payout_address`, `loyalty_policy_id`, `mint_params`, `next_listing_id`, `listings_count`, `merchant_id` | public | Read-only getters |
| merchant | `set_payout_address`, `set_display` | public (cap-gated) | Mutable display + routing |
| merchant | `add_listing`, `set_listing_price`, `set_listing_name`, `set_listing_active`, `remove_listing`, `borrow_listing`, `contains_listing` | public (cap-gated for writes) | Listing CRUD |
| merchant | `assert_cap_matches` | public | Assertion helper used by other modules |
| merchant | `loyalty_treasury_cap_mut` | pkg | Borrow cap for mint/burn |
| listing | `listing_id`, `listing_name`, `listing_price`, `listing_active` | public | Accessors on `Listing` |
| listing | `new`, `set_price`, `set_name`, `set_active` | pkg | Mutators (only `merchant` calls) |
| merchant | `issue_invoice(m, &cap, amount, order_ref, ttl_ms, &clock, ctx) -> Invoice` | public (cap-gated) | Merchant issues invoice |
| merchant | `pay<S>(m, invoice, send_req, &policy_s, &customer_LOY_account, &clock, ctx)` | public | Customer settles — moves stablecoin, mints loyalty, destroys invoice, emits |
| invoice | `share(invoice)` | public | Share the invoice |
| invoice | `cancel(invoice, &clock)` | public (permissionless after expiry) | Cleanup unused invoice |
| invoice | `merchant_id`, `payout_address`, `amount`, `order_ref`, `expires_at_ms` | public | Read accessors on `Invoice` |
| invoice | `new(...)`, `destroy(invoice)` | pkg | Construction + consumption (called by `merchant`) |
| redemption | `create_voucher(m, &cap, amount, ttl_ms, &clock, ctx) -> RedemptionVoucher` | public (cap-gated) | Merchant issues voucher |
| redemption | `share_voucher(voucher)` | public | Share the voucher |
| redemption | `redeem(m, voucher, unlock_req, &policy_loyalty, &clock, ctx)` | public | Customer redeems — burns loyalty, destroys voucher, emits |
| redemption | `cancel_voucher(voucher, &clock)` | public (permissionless after expiry) | Cleanup unused voucher |
| events | `InvoicePaid`, `VoucherRedeemed` | public | Event struct definitions |
| events | `emit_invoice_paid`, `emit_voucher_redeemed` | pkg | Emit helpers |
| stablecoin_mock | `init(otw, ctx)` | private (auto-called) | Create mock currency |
| stablecoin_mock | `setup(namespace, &mut treasury_cap, ctx)` | public | Create Policy + register TransferApproval |
| stablecoin_mock | `approve_transfer(&mut request)` | public | Stamp `TransferApproval` witness on a send_funds request (called by customer PTB) |
| stablecoin_mock | `faucet(cap, recipient_account, amount)` | public | Devnet mint into a recipient's PAS Account |

### Object ownership model

| Object | Visibility | Lifetime | Module |
|---|---|---|---|
| `Merchant` | shared | permanent | merchant |
| `MerchantCap` | owned (`key, store`) | permanent | merchant |
| `Loyalty` | owned (`key`-only) | ephemeral (between bootstrap txs) | loyalty |
| `Policy<Balance<LOYALTY>>` | shared | permanent | loyalty (PAS-typed) |
| `Policy<Balance<STABLECOIN_MOCK>>` | shared | permanent | stablecoin_mock (PAS-typed) |
| `CoinMetadata<LOYALTY>`, `CoinMetadata<STABLECOIN_MOCK>` | shared + frozen | permanent | each currency module |
| `Invoice` | shared, short-lived | merchant issues → customer settles or anyone cancels after expiry | payment |
| `RedemptionVoucher` | shared, short-lived | merchant issues → customer redeems or anyone cancels after expiry | redemption |
| PAS `Account` (per user, per asset type via namespace) | shared | per-user | PAS (created lazily via `account::create_and_share`) |
| PAS `Namespace` | shared, singleton | permanent | PAS infrastructure |
| `TreasuryCap<LOYALTY>`, `TreasuryCap<STABLECOIN_MOCK>` | wrapped in `Merchant` / owned by deployer | permanent | sui::coin |
| `PolicyCap<Balance<LOYALTY>>`, `PolicyCap<Balance<STABLECOIN_MOCK>>` | wrapped in `Merchant` / owned by deployer | permanent | pas::policy |

### Events

- `events::InvoicePaid { invoice_id, merchant_id, order_ref, customer, amount, loyalty_minted, timestamp_ms }` — emitted by `payment::pay`
- `events::VoucherRedeemed { voucher_id, merchant_id, customer, amount, timestamp_ms }` — emitted by `redemption::redeem`

No `Created` or `Cancelled` events in v1 — merchant has the intent ID synchronously from `create_*`; cancellation is silent object-destruction. Add later if indexers need them.

### Error constants

- **merchant**: `EWrongMerchantCap (0)`, `EEmptyName (1)`, `EZeroMintDenominator (2)`, `EListingNotFound (3)`, `EWrongMerchantForInvoice (4)`, `EInvoiceExpired (5)`, `EAmountMismatch (6)`, `EWrongRecipient (7)`, `EWrongLoyaltyRecipient (8)`, `EInvoiceZeroAmount (9)`, `EInvoiceZeroTtl (10)`
- **listing**: `EEmptyName (0)`, `EZeroPrice (1)`
- **invoice**: `ENotExpired (0)`
- **redemption**: `EZeroAmount (0)`, `EZeroTtl (1)`, `EWrongMerchantForVoucher (2)`, `EExpired (3)`, `ENotExpired (4)`, `EAmountMismatch (5)`

## Invariant Enforcement Map

### Type-level (enforced by struct definitions / abilities / visibility)

| Invariant | Enforcement Location | Mechanism |
|---|---|---|
| INV-1 Loyalty bundle must be consumed | `loyalty::Loyalty` | `has key` only — no `drop`, `store`, `copy` |
| INV-2 MerchantCap is transferable | `merchant::MerchantCap` | `has key, store` |
| INV-3 Loyalty is soulbound | `loyalty::setup` | No `send_funds` approval registered |
| INV-4 No clawback on loyalty | `loyalty::setup` | `clawback_allowed = false` + no `clawback_funds` approval |
| INV-5 Only redemption can unlock loyalty | `loyalty::setup` + `new_redeem_unlock_approval` | Approval witness constructor is `public(package)` |
| INV-6 External packages cannot mint LOYALTY | `loyalty::mint_into` | `public(package)` only |
| INV-7 Invoice / RedemptionVoucher cannot be silently dropped | both structs | `has key` only |

### Runtime (assert! statements)

| Invariant | Enforcement Location | Error |
|---|---|---|
| INV-8 MerchantCap must match Merchant | `merchant::assert_cap_matches` | `EWrongMerchantCap` |
| INV-9 Merchant name non-empty | `merchant::create`, `set_display` | `EEmptyName` |
| INV-10 Mint denominator non-zero | `merchant::create` | `EZeroMintDenominator` |
| INV-11 Listing name non-empty | `listing::new`, `listing::set_name` | `EEmptyName` |
| INV-12 Listing price non-zero | `listing::new`, `listing::set_price` | `EZeroPrice` |
| INV-13 Listing must exist before mutating | `merchant::set_listing_*`, `remove_listing`, `borrow_listing` | `EListingNotFound` |
| INV-14 Invoice amount non-zero | `merchant::issue_invoice` | `EInvoiceZeroAmount` |
| INV-15 Invoice ttl > 0 | `merchant::issue_invoice` | `EInvoiceZeroTtl` |
| INV-16 Invoice merchant_id matches | `merchant::pay` | `EWrongMerchantForInvoice` |
| INV-17 Pay before expiry | `merchant::pay` | `EInvoiceExpired` |
| INV-18 Cancel only after expiry | `invoice::cancel` | `ENotExpired` |
| INV-19 Send amount matches Invoice amount | `merchant::pay` | `EAmountMismatch` |
| INV-20 Send recipient matches Merchant payout | `merchant::pay` | `EWrongRecipient` |
| INV-21 Loyalty mints to payer's own account | `merchant::pay` | `EWrongLoyaltyRecipient` |
| INV-22 Mint bounded by max | `merchant::pay` | (clamp, not assert) |
| INV-23 No mint overflow | `merchant::pay` | u128 intermediate |
| INV-24 Voucher amount non-zero | `redemption::create_voucher` | `EZeroAmount` |
| INV-25 Voucher ttl > 0 | `redemption::create_voucher` | `EZeroTtl` |
| INV-26 Voucher merchant_id matches | `redemption::redeem` | `EWrongMerchantForVoucher` |
| INV-27 Redeem before expiry | `redemption::redeem` | `EExpired` |
| INV-28 Cancel only after expiry | `redemption::cancel_voucher` | `ENotExpired` |
| INV-29 Unlock amount matches Voucher amount | `redemption::redeem` | `EAmountMismatch` |

## Implementation Notes

- **Burn pattern:** `coin::burn_balance` does not exist in this Sui framework rev. Use `balance::decrease_supply(coin::supply_mut(cap), funds)` instead.
- **Move 2024 method-call syntax** used throughout (`m.payout_address()`, `clock.timestamp_ms()`, `id.delete()`, `request.approve(witness)`, etc.).
- **u128 intermediate** in `payment::pay`'s mint computation to dodge overflow when `payment_amount * mint_numerator` exceeds u64.
- **Snapshot-before-consume pattern** in `payment::pay` and `redemption::redeem`: read all needed fields *before* any destructure or consuming move (e.g., `let order_ref = invoice.order_ref;` before `let Invoice { id, .. } = invoice;`).
- **`stablecoin_mock` uses modern `coin_registry::new_currency_with_otw`** matching the loyalty example pattern.
- **`stablecoin_mock::setup` annotated `#[allow(lint(self_transfer))]`** — the lint flags the `transfer::public_transfer(policy_cap, ctx.sender())` line; intentional for the mock.
- **IDE spell-check / LSP noise** on domain terms (`soulbound`, `clawback`, `permissionless`, `MOCKUSD`, etc.) and occasional stale `unused use` warnings — informational; build is the source of truth.

## Out of Scope

- **Tests** — next stage (`/sui-tests`). No `*_tests.move` files yet.
- **Receipt NFTs** — deferred to v2 per dev spec.
- **Confidential transfers, loyalty leaderboard, multiple custom attributes per listing** — deferred per dev spec.
- **Multi-merchant / marketplace support** — single-tenant template by design.
- **Real fiat off-ramp** — mock only; real integration is a separate workstream.
- **Real production stablecoin path** — template is generic over `S`; forks swap in their PAS-issued stablecoin (e.g. S3 / S3.MONEY). USDC-as-`Coin` is unsupported (this version explicitly uses PAS for the stablecoin side).
- **On-chain order-ref replay protection** — `order_ref` reuse across invoices is the indexer's responsibility (or a frontend uniqueness check). On-chain dedup would require a `Table<vector<u8>, bool>` on Merchant that grows without bound.
- **Runtime mutation of mint policy params** — write-once at `create`. Future controlled migration would require a new function.
- **Runtime policy adjustment entry** — `PolicyCap`s are held but no entry exposes them in v1.
- **Withdrawal helper for merchant** — merchant uses PAS directly (`account::send_balance`, etc.) on their payout `Account<S>`.
- **Frontend / TS SDK** — out of scope for this Move-only stage.
- **Merchant events** (`MerchantCreated`, `ListingAdded`, `InvoiceCreated`, `VoucherCreated`, `InvoiceCancelled`, etc.) — only Paid / Redeemed events ship in v1.
- **`pause`/`unpause`** emergency stop — not in v1.
- **OZ AccessControl migration** — Sui-native capability pattern in v1.
- **Second redemption flow** — the `// TODO#q` in `redemption.move` flags a future "user-driven verify" path alongside the current merchant-only one. Not in v1.

## Dev Notes

- The design conversation produced renames mid-stream: `MerchantConfig → Merchant`; `LoyaltyBootstrap → Loyalty` (moved from `merchant.move` to `loyalty.move`); `setup_loyalty → setup`; `Catalog` removed entirely (folded into `Merchant.listings`); `create_merchant → create`; merchant grew `share`; the original `Hold` shared object holding `Balance<LOYALTY>` became `RedemptionVoucher` (merchant-issued, no balance held).
- **Pivot back from `Coin<S>` to PAS-managed stablecoin.** An earlier iteration switched the stablecoin side to plain `Coin<S>` (arguing real production stablecoins like Circle USDC on Sui are Coin-based, not PAS). Reversed after the dev decided the template's value is demonstrating end-to-end PAS workflows for both asset sides. Forks needing Coin-side payment can simplify; the canonical template is PAS for both.
- **Symmetric intent-object workflow.** Replaces the earlier customer-initiated `Redemption` (held `Balance<LOYALTY>`) with merchant-issued `Invoice` / `RedemptionVoucher`. Stronger customer protection (balance never locked between issuance and settlement), simpler lifecycle (no permissionless-release path needed since no balance is held by the intent), more parallel design.
- **`payment.move` reintroduced, then renamed to `invoice.move` and slimmed down.** A naive split would put `create_invoice` + `pay` in `invoice.move` with `&Merchant`/`&MerchantCap` deps; combined with `merchant.move` needing `Invoice` for `pay`, this creates a module dependency cycle Move forbids. Resolved by moving `pay` AND `issue_invoice` (renamed from `create_invoice` because `merchant::create` is taken by the Merchant constructor) into `merchant.move`, leaving `invoice.move` with just the struct + `share` / `cancel` / accessors + pkg `new`/`destroy`. The verb "issue" matches business parlance for invoice issuance.
- **Stablecoin mock is now PAS-managed.** `STABLECOIN_MOCK` OTW (kept; user choice), `Policy<Balance<STABLECOIN_MOCK>>` with permissive `TransferApproval`, `approve_transfer` helper the customer's PTB calls, faucet that deposits into a PAS Account.
- **Customer payment PTB shape** (frontend-composed): create_and_share namespace accounts if missing → `new_auth` → `send_balance` to create send-funds request → `stablecoin_mock::approve_transfer` → `payment::pay<STABLECOIN_MOCK>(merchant, invoice, sf_req, policy_s, customer_LOY, &clock, ctx)`. Lazy account creation handled in the frontend.
- PAS dep was originally a git URL pinned to commit `b64f0c5`. Vendored at `vendor/pas/` because PAS doesn't declare a `test-publish` environment.
- We skipped the standard pipeline order (research → design → invariants → code → tests → docs) by jumping from research directly to code-draft, with design + invariants merged into this artifact.

## Open Questions

1. **Tests** — `/sui-tests` is the next skill. Target coverage: every runtime invariant + happy paths for both Invoice and Voucher lifecycles (issued → paid/redeemed → event; issued → expired → cancelled) + edge cases (amount mismatch, expired invoice, cross-merchant invoice, missing PAS accounts).
2. **Second redemption flow (user-initiated)** — the `// TODO#q` in `redemption.move` flags a future user-driven settle path alongside the current merchant-only one. What's the desired shape? Symmetric to the merchant-only flow but with customer auth as the gate?
3. **`Invoice.order_ref` vs `RedemptionVoucher` (no order_ref)** — payment carries the merchant's internal order id; redemption doesn't. If audit/indexer wants a redemption ref too, add `order_ref: vector<u8>` to the voucher.
4. **Pre-commit hook to strip `[pinned.test-publish.*]` from `Move.lock`** before commit (OZ AMM does this).
5. **`Created` / `Cancelled` events** — currently v1 only emits Paid / Redeemed. Add the others if external indexers need to track the full intent lifecycle on-chain.
