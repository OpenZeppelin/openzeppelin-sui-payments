---
stage: code
project: openzeppelin-sui-payments
mode: greenfield
extends: null
status: draft
timestamp: 2026-05-19
author: Alisander Qoshqosh
previous_stage: artifacts/01-research.md
tags: [pas, payments, loyalty, soulbound, qr-payments, design-merged]
---

# OpenZeppelin Sui Payments — Code Draft (with merged design + invariants notes)

## Summary

Five Move modules implementing a closed-loop stablecoin payment + soulbound loyalty + code-bound redemption template on Sui. The stablecoin side uses **plain `Coin<S>`** (matches production reality — Circle USDC on Sui is Coin-based, not PAS). The loyalty side uses **PAS** for soulbound enforcement and code-gated redemption. Build clean against the testnet Sui framework and a vendored copy of `MystenLabs/pas @ b64f0c5`. **No `02-design.md` or `03-invariants.md` were produced separately** — design decisions and invariants are merged into this document at the dev's request after the design conversation became sufficiently concrete to skip the formal handoff. Pipeline therefore: research (01) → code (this document, 04).

## Modules

| Module | Lines | Status | Purpose |
|---|---|---|---|
| `payments::loyalty` | 129 | Draft | LOYALTY OTW + `Loyalty` bundle + `RedeemUnlockApproval` witness + PAS Policy setup + pkg-private `mint_into` |
| `payments::merchant` | 261 | Draft | `Merchant` shared state + `MerchantCap` + `create`/`share` + cap-gated mutators + listing CRUD + `pay<S>` |
| `payments::listing` | 60 | Draft | Pure data type — `Listing` struct + pkg-private constructors/setters + public accessors |
| `payments::redemption` | 164 | Draft | `Redemption` shared object + `create`/`share` / `verify` / `release` with sha3-256 commit-reveal |
| `payments::events` | 96 | Draft | All event structs (`PaymentEvent`, `RedemptionCreated`, `RedemptionVerified`, `RedemptionReleased`) + pkg-private `emit_*` helpers |
| `stablecoin_mock` | 44 | Draft | Mock `Coin<STABLECOIN_MOCK>` + permissionless faucet (devnet only) |
| **total** | **754** | | |

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
    │   └── sources/{merchant,listing,loyalty,redemption,events}.move
    └── stablecoin-mock/                    # peer package — plain Sui Coin, no PAS
        ├── Move.toml
        └── sources/stablecoin_mock.move
```

Mirrors `openzeppelin-sui-amm`'s layout: `packages/dapp/contracts/<pkg>/` with mocks as sibling packages.

### Key design decisions

1. **No `access` module / shim.** Sui-native capability pattern: every gated entry takes `&MerchantCap`, validated via `merchant::assert_cap_matches`. Migration to OZ AccessControl when available is a future stage; not designed for now.
2. **Single shared `Merchant` object** holds *everything* per-merchant: identity, payout, loyalty caps + policy IDs, mint policy params, and listings `Table<u64, Listing>`. No separate `Catalog` (1:1 with mutual ID refs was the alternative considered and rejected).
3. **Listing CRUD AND payment live in `merchant.move`** (marketplace pattern). `listing.move` defines only the struct + package-private setters + accessors. `merchant.move` owns all functions that mutate `Merchant`'s state — listings, payout, and `pay<S>`. Avoids circular imports and keeps the merchant-side surface in one file.
4. **Two-tx onboarding (forced by Sui Move init constraints).** Publish runs `loyalty::init` which creates only the Sui coin + freezes metadata; the deployer's second tx is a PTB calling `loyalty::setup(&mut namespace, treasury_cap)` then `merchant::create(loyalty, name, …)`. The `Loyalty` bundle is the hot-potato handoff between the two functions in the PTB.
5. **PAS Namespace is global** (singleton per PAS publish), not per-merchant. So `Merchant` does NOT carry a `loyalty_namespace_id` field. Functions needing namespace take `&mut Namespace` as a separate shared input.
6. **Mint policy params are immutable** post-`create`. No runtime mutator. Changing "$1 = X points" under existing customers is a trust regression.
7. **PolicyCap is held inside `Merchant`** for future controlled policy migration, but **no runtime adjustment entry is exposed in v1**. Soulbound is permanent.
8. **Payment verification is events-only** — port of Solana Pay's `reference` pattern. `PaymentEvent { merchant_id, order_ref, customer, amount, loyalty_minted, timestamp_ms }`. Indexer subscribes by `merchant_id`, resolves `order_ref → settled?`. No on-chain `PaymentIntent` object.
9. **Redemption is a shared object carrying `Balance<LOYALTY>`** extracted from the customer's PAS Account via `unlock_funds::resolve`. Hash-commit-reveal binds an off-chain `code` to `sha3_256(code)`. `release` is permissionless after expiry; balance returns to the original customer's account.
10. **Lazy in-payment Account creation** for the customer's loyalty Account — frontend's PTB step 0 calls `account::create_and_share(&mut namespace, customer)` if it doesn't exist. Permissionless in PAS. Contention bounded to first-time customers.
11. **Loyalty asset is a standard Sui Coin (decimals 0)** wrapped with `Policy<Balance<LOYALTY>>` that registers approvals only for `unlock_funds` — `send_funds` and `clawback_funds` have no approvals → soulbound, no clawback.
12. **Stablecoin is plain `Coin<S>`, NOT PAS.** Matches production reality (Circle USDC on Sui is Coin-based). Customer's PTB just passes a split-off `Coin<S>` to `payment::pay<S>`; the function routes it to `merchant.payout_address` via `transfer::public_transfer`. No PAS Account, no Policy, no approval witness on the stablecoin side. Forks needing issuer-controlled compliance hooks can add a PAS wrapper back to the payment side; the rest of the template doesn't need to change.

### Public API surface

| Module | Function | Visibility | Purpose |
|---|---|---|---|
| loyalty | `init(otw, ctx)` | private (auto-called) | Create currency + freeze metadata |
| loyalty | `setup(namespace, cap, ctx) -> Loyalty` | public | Create Policy, register approvals, bundle outputs |
| loyalty | `destruct(loyalty) -> (TreasuryCap, PolicyCap, ID)` | pkg | Consumed by `merchant::create` |
| loyalty | `mint_into(cap, account, amount)` | pkg | Called by `merchant::pay` |
| loyalty | `new_redeem_unlock_approval() -> RedeemUnlockApproval` | pkg | Called by `redemption::create` |
| merchant | `create(loyalty, ...) -> (Merchant, MerchantCap)` | public | Consume Loyalty; return Merchant + cap |
| merchant | `share(merchant)` | public | Share the Merchant (required — `key`-only, so `share_object` is defining-module-restricted) |
| merchant | `name`, `logo_url`, `payout_address`, `loyalty_policy_id`, `mint_params`, `next_listing_id`, `listings_count`, `merchant_id` | public | Read-only getters |
| merchant | `set_payout_address`, `set_display` | public (cap-gated) | Mutable display + routing |
| merchant | `add_listing`, `set_listing_price`, `set_listing_name`, `set_listing_active`, `remove_listing`, `borrow_listing`, `contains_listing` | public (cap-gated for writes) | Listing CRUD |
| merchant | `assert_cap_matches` | public | Assertion helper used by other modules |
| merchant | `pay<S>(merchant, coin, customer_loyalty_account, order_ref, clock, ctx)` | public | Route `Coin<S>` to payout + mint loyalty + emit `PaymentEvent` |
| merchant | `loyalty_treasury_cap_mut` | pkg | Borrow cap for mint/burn |
| listing | `listing_id`, `listing_name`, `listing_price`, `listing_active` | public | Accessors on `Listing` |
| listing | `new`, `set_price`, `set_name`, `set_active` | pkg | Mutators (only `merchant` calls) |
| events | `PaymentEvent`, `RedemptionCreated`, `RedemptionVerified`, `RedemptionReleased` | public | Event struct definitions |
| events | `emit_payment`, `emit_redemption_created`, `emit_redemption_verified`, `emit_redemption_released` | pkg | Emit helpers (called by `merchant::pay`, `redemption::*`) |
| redemption | `create(merchant, request, policy_loyalty, code_hash, ttl_ms, clock, ctx) -> Redemption` | public | Extract balance into a Redemption |
| redemption | `share(redemption)` | public | Share the Redemption (`key`-only, defining-module-restricted) |
| redemption | `verify(merchant, cap, redemption, code, clock)` | public (cap-gated) | Burn on preimage match |
| redemption | `release(redemption, customer_loyalty_account, clock)` | public (permissionless after expiry) | Return balance |
| stablecoin_mock | `init(otw, ctx)` | private (auto-called) | Create currency, freeze metadata, share TreasuryCap |
| stablecoin_mock | `faucet(cap, amount, ctx)` | public | Permissionless dev faucet |

### Object ownership model

| Object | Visibility | Lifetime | Module |
|---|---|---|---|
| `Merchant` | shared | permanent | merchant |
| `MerchantCap` | owned (`key, store`) | permanent | merchant |
| `Loyalty` | owned (`key`-only, no drop/store) | ephemeral (between bootstrap txs) | loyalty |
| `Policy<Balance<LOYALTY>>` | shared | permanent | loyalty (PAS-typed) |
| `CoinMetadata<LOYALTY>` | shared + frozen | permanent | loyalty |
| `Coin<S>` (stablecoin) | owned by sender / payout address | per-payment object | sui::coin |
| `Redemption` | shared | short (minutes) | redemption |
| `Account<LOYALTY>` (per customer) | shared | per-customer | PAS (created via `account::create_and_share`) |
| PAS `Namespace` | shared, singleton | permanent | PAS infrastructure |
| `TreasuryCap<STABLECOIN_MOCK>` | shared | permanent (devnet) | stablecoin-mock |

### Events

All events defined in `events.move` (matches OZ AMM convention — centralised event surface, `public(package)` `emit_*` helpers). No merchant-management events in v1 (deferred — add `MerchantCreated`, `ListingAdded`, etc. when needed).

- `events::PaymentEvent { merchant_id, order_ref, customer, amount, loyalty_minted, timestamp_ms }` — emitted by `merchant::pay`
- `events::RedemptionCreated { redemption_id, merchant_id, customer, amount, expires_at_ms }` — emitted by `redemption::create`
- `events::RedemptionVerified { redemption_id, merchant_id, customer, amount }` — emitted by `redemption::verify`
- `events::RedemptionReleased { redemption_id, merchant_id, customer, amount }` — emitted by `redemption::release`

### Error constants

All modules use the new `#[error(code = N)] const E... : vector<u8> = b"...";` attribute pattern (vs legacy `const E... : u64 = N;`), matching PAS convention.

- **merchant**: `EWrongMerchantCap (0)`, `EEmptyName (1)`, `EZeroMintDenominator (2)`, `EListingNotFound (3)`, `EWrongLoyaltyRecipient (4)`
- **listing**: `EEmptyName (0)`, `EZeroPrice (1)`
- **redemption**: `EEmptyCodeHash (0)`, `EZeroTtl (1)`, `EZeroAmount (2)`, `EWrongMerchantForRedemption (3)`, `EExpired (4)`, `ENotExpired (5)`, `EWrongCode (6)`, `EWrongCustomer (7)`

## Invariant Enforcement Map

### Type-level (enforced by struct definitions / abilities / visibility)

| Invariant | Enforcement Location | Mechanism |
|---|---|---|
| INV-1 Loyalty bundle must be consumed | `loyalty::Loyalty` | `has key` only — no `drop`, `store`, `copy` |
| INV-2 MerchantCap is transferable | `merchant::MerchantCap` | `has key, store` |
| INV-3 Redemption cannot be silently dropped | `redemption::Redemption` | `has key` only |
| INV-4 Loyalty is soulbound | `loyalty::setup` | No `send_funds` approval registered |
| INV-5 No clawback | `loyalty::setup` | `clawback_allowed = false` + no `clawback_funds` approval |
| INV-6 Only redemption can unlock loyalty | `loyalty::setup` + `new_redeem_unlock_approval` | Approval witness constructor is `public(package)` |
| INV-7 External packages cannot mint LOYALTY | `loyalty::mint_into` | `public(package)` only |
| INV-8 Payment routes to `payout_address` by construction | `merchant::pay` | Hard-coded `transfer::public_transfer(coin, payout)` — no caller-controlled recipient field |

### Runtime (assert! statements)

| Invariant | Enforcement Location | Error |
|---|---|---|
| INV-9 MerchantCap must match Merchant | `merchant::assert_cap_matches` (called by all cap-gated entries) | `EWrongMerchantCap` |
| INV-10 Merchant name non-empty | `merchant::create`, `set_display` | `EEmptyName` |
| INV-11 Mint denominator non-zero | `merchant::create` | `EZeroMintDenominator` |
| INV-12 Listing name non-empty | `listing::new`, `listing::set_name` | `EEmptyName` |
| INV-13 Listing price non-zero | `listing::new`, `listing::set_price` | `EZeroPrice` |
| INV-14 Listing must exist before mutating | `merchant::set_listing_*`, `remove_listing`, `borrow_listing` | `EListingNotFound` |
| INV-15 Loyalty mints to payer's own account | `merchant::pay` | `EWrongLoyaltyRecipient` |
| INV-16 Mint bounded by max | `merchant::pay` | (clamp, not assert) |
| INV-17 No mint overflow | `merchant::pay` | u128 intermediate |
| INV-18 Redemption code_hash non-empty | `redemption::create` | `EEmptyCodeHash` |
| INV-19 Redemption ttl > 0 | `redemption::create` | `EZeroTtl` |
| INV-20 Redemption amount > 0 | `redemption::create` | `EZeroAmount` |
| INV-21 Verify before expiry | `redemption::verify` | `EExpired` |
| INV-22 Release after expiry | `redemption::release` | `ENotExpired` |
| INV-23 Code preimage matches commitment | `redemption::verify` | `EWrongCode` |
| INV-24 Verify only on Redemption for this merchant | `redemption::verify` | `EWrongMerchantForRedemption` |
| INV-25 Release deposits only to original customer | `redemption::release` | `EWrongCustomer` |

## Implementation Notes

- **Stablecoin pivot (mid code-draft).** Initial design had `payment::pay<S>` taking a `Request<SendFunds<Balance<S>>>` and treating the stablecoin as PAS-managed. Refactored to plain `Coin<S>` after dev called out that real production stablecoins (USDC on Sui) are Coin-based — the PAS wrapper added onboarding friction (customer needs `Account<S>`, issuer needs `approve_transfer`) without buying real-world value. Loyalty stays on PAS for soulbound enforcement.
- **Burn API quirk:** `coin::burn_balance` does not exist in the Sui framework rev pinned (`c2428b3`). Used `balance::decrease_supply(coin::supply_mut(cap), funds)` instead. Inline comment in `redemption::verify`.
- **Move 2024 method-call syntax** used throughout for readability (e.g. `merchant.payout_address()`, `clock.timestamp_ms()`, `id.delete()`). Resolves via first-arg type matching.
- **u128 intermediate** in `merchant::pay`'s mint computation to dodge overflow when `payment_amount * mint_numerator` exceeds u64.
- **Snapshot-before-consume pattern** in `merchant::pay` and `redemption::verify`: read all needed fields *before* any destructure or consuming move.
- **`hash::sha3_256` chosen** over Sui-native `blake2b256` for cross-platform compatibility (any client can compute the preimage hash trivially in JS, Python, etc.).
- **No events on merchant operations** (e.g. `MerchantCreated`, `ListingAdded`) in v1 — only payment/redemption flows emit events. Deferred until a clear indexer requirement emerges.
- **`stablecoin_mock` uses modern `coin_registry::new_currency_with_otw`** (the legacy `coin::create_currency` is deprecated). Mirrors the loyalty example's pattern.
- **`stablecoin_mock::faucet` is annotated `#[allow(lint(self_transfer))]`** — the lint flags the standard "mint to caller" pattern. Same approach as PAS examples.
- **IDE spell-check / LSP noise** on domain terms (`soulbound`, `clawback`, `preimage`, `permissionless`, `Solana`, `Mysten`, `devnet`) and occasional stale `unused use` warnings — informational only; build is the source of truth.

## Out of Scope

- **Tests** — next stage (`/sui-tests`). No `*_tests.move` files yet.
- **Receipt NFTs** — deferred to v2 per dev spec; the `PaymentEvent` shape is extensible.
- **Confidential transfers, loyalty leaderboard, multiple custom attributes per listing** — deferred per dev spec.
- **Multi-merchant / marketplace support** — single-tenant template by design.
- **Real fiat off-ramp** — mock only; real integration is a separate workstream.
- **PAS-wrapped stablecoin path** — v1 uses plain `Coin<S>` because production stablecoins (Circle USDC on Sui) are Coin-based. Forks needing issuer-controlled compliance hooks can layer PAS on top, but the template doesn't ship that variant.
- **On-chain replay protection for payments** — `order_ref` reuse is the indexer's responsibility.
- **Runtime mutation of mint policy params** — write-once at `create`. Future controlled migration would require a new function.
- **Runtime policy adjustment entry** — `PolicyCap` is held inside `Merchant` for future use; no entry exposes it in v1.
- **`withdraw_balance<S>` helper** — merchant manages their wallet's accumulated `Coin<S>` objects directly (standard Sui — `coin::join`, `transfer::public_transfer`, etc.).
- **Frontend / TS SDK** — out of scope for this Move-only stage.
- **Merchant events** (`MerchantCreated`, `ListingAdded`, etc.) — deferred.
- **`pause`/`unpause`** emergency stop — not in v1.
- **OZ AccessControl migration** — Sui-native capability pattern in v1; AccessControl is a future-stage concern when that library is released and audited.

## Dev Notes

- The design conversation produced renames mid-stream: `MerchantConfig → Merchant`; `LoyaltyBootstrap → Loyalty` (moved from `merchant.move` to `loyalty.move` with a `public(package) destruct` helper); `setup_loyalty → setup`; `Catalog` removed entirely (folded into `Merchant.listings`); `payment.move` removed entirely (folded `pay<S>` into `merchant.move`, same reasoning as listing CRUD — functions that mutate `Merchant` live where the state lives).
- **Events extracted to dedicated `events.move`** mid-code-draft to match OZ AMM convention. All four event structs (`PaymentEvent`, `RedemptionCreated`, `RedemptionVerified`, `RedemptionReleased`) plus `public(package)` `emit_*` helpers live there. Call sites use the helpers rather than constructing structs and calling `event::emit` directly.
- **Mid-code-draft pivot from PAS-stablecoin to plain `Coin<S>`** — dropped `EWrongRecipient` (now enforced by construction, see INV-8), removed the `Account<S>` ownership row, simplified the stablecoin-mock from PAS-issued to a plain Sui Coin with a faucet. Original (PAS-stablecoin) design is documented in this artifact's history for reference.
- PAS dep was originally a git URL pinned to commit `b64f0c5`. Switched to **vendored** at `vendor/pas/` because PAS doesn't declare a `test-publish` environment and we needed to add it locally (matches OZ AMM convention). `Move.lock` files now committed.
- The edition mismatch I worried about (`2024` vs `2024.beta`) was a non-issue: the original failure was actually `[addresses]` + `[environments]` conflicting in the same Move.toml. PAS new-style + ours new-style works fine.
- We skipped the standard pipeline order (research → design → invariants → code → tests → docs) by jumping from research directly to code-draft, with design + invariants merged into this artifact. Trade-off accepted by the dev; documented here so future skill invocations on this project know the artifact history is non-canonical.
- `.vscode/tasks.json` uses `--build-env test-publish` for build + test.

## Open Questions

1. **Tests** — `/sui-tests` is the next skill. Target coverage: every runtime invariant + happy paths + the three Redemption lifecycle outcomes (verify, release, abort-on-bad-code) + the `Coin<S>`-based payment flow (no PAS approval machinery to test on the stablecoin side now).
2. **Pre-commit hook to strip `[pinned.test-publish.*]` from `Move.lock`** before commit (OZ AMM does this) — worth adopting before contributors land.
3. **Mock vs vendored PAS for future updates** — vendoring captures PAS at one commit. When PAS updates upstream we manually re-sync. Acceptable trade-off; documented in the README would help future contributors.
4. **Add events to merchant operations** if/when the dashboard indexer wants them (`MerchantCreated`, `ListingAdded { id, name, price }`, `MerchantPolicyChanged`, etc.). Defer until concrete need.
5. **`destroy_zero` defensive check?** If a Redemption ends up with a zero balance somehow (shouldn't happen given INV-20), burn / release would behave fine but `balance::decrease_supply(0)` is wasted gas. Probably skip for v1 — INV-20 catches it upstream.
6. **Should `stablecoin_mock::faucet` cap per-call amount?** Currently unbounded — anyone can mint any amount. Fine for devnet; could add a `MAX_PER_FAUCET_CALL` constant if testers spam it.
