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

Five Move modules implementing a closed-loop stablecoin payment + soulbound loyalty + code-bound redemption template on Sui's Permissioned Asset Standard (PAS). Build clean against the testnet Sui framework and a vendored copy of `MystenLabs/pas @ b64f0c5`. **No `02-design.md` or `03-invariants.md` were produced separately** — design decisions and invariants are merged into this document at the dev's request after the design conversation became sufficiently concrete to skip the formal handoff. The pipeline is therefore: research (01) → code (this document, 04).

## Modules

| Module | Lines | Status | Purpose |
|---|---|---|---|
| `loyalty.move` | 123 | Draft | LOYALTY OTW + `Loyalty` bundle + `RedeemUnlockApproval` witness + PAS Policy setup + pkg-private `mint_into` |
| `merchant.move` | 220 | Draft | `Merchant` shared state + `MerchantCap` + bootstrap (`create_merchant`) + cap-gated mutators + listing CRUD |
| `listing.move` | 53 | Draft | Pure data type — `Listing` struct + pkg-private constructors/setters + public accessors |
| `payment.move` | 99 | Draft | `pay<S>` — atomic stablecoin spend + loyalty mint + `PaymentEvent` |
| `redemption.move` | 170 | Draft | `Hold` shared object + `request_redeem` / `verify` / `release` with sha3-256 commit-reveal |
| **total** | **665** | | |

Mock PAS stablecoin package (`packages/dapp/contracts/stablecoin-mock`) is scaffolded with stub modules only — implementation is open work (see Out of Scope).

## Design Context (merged from skipped `02-design.md`)

### Repository layout

```
.
├── artifacts/                              # stage artifacts (this is 04-code.md)
├── vendor/pas/                             # vendored MystenLabs/pas @ b64f0c5,
│                                            with [environments] test-publish added
└── packages/dapp/contracts/
    ├── payments/                           # main Move package
    │   ├── Move.toml                       (edition "2024", local dep on vendor/pas)
    │   └── sources/{merchant,listing,payment,loyalty,redemption}.move
    └── stablecoin-mock/                    # peer package, scaffold only
        ├── Move.toml
        └── sources/stablecoin_mock.move
```

Mirrors `openzeppelin-sui-amm`'s layout: `packages/dapp/contracts/<pkg>/` with mocks as sibling packages.

### Key design decisions

1. **No `access` module / shim.** Sui-native capability pattern: every gated entry takes `&MerchantCap`, validated via `merchant::assert_cap_matches`. Migration to OZ AccessControl when available is a future stage; not designed for now.
2. **Single shared `Merchant` object** holds *everything* per-merchant: identity, payout, loyalty caps + policy IDs, mint policy params, and listings `Table<u64, Listing>`. No separate `Catalog` (1:1 with mutual ID refs was the alternative considered and rejected).
3. **Listing CRUD lives in `merchant.move`** (marketplace pattern). `listing.move` defines only the struct + package-private setters + accessors. Circular import would result if CRUD lived in `listing.move`.
4. **Two-tx onboarding (forced by Sui Move init constraints).** Publish runs `loyalty::init` which creates only the Sui coin + freezes metadata; the deployer's second tx is a PTB calling `loyalty::setup(&mut namespace, treasury_cap)` then `merchant::create_merchant(loyalty, name, …)`. The `Loyalty` bundle is the hot-potato handoff between the two functions in the PTB.
5. **PAS Namespace is global** (singleton per PAS publish), not per-merchant. So `Merchant` does NOT carry a `loyalty_namespace_id` field. Functions needing namespace take `&mut Namespace` as a separate shared input.
6. **Mint policy params are immutable** post-`create_merchant`. No runtime mutator. Changing "$1 = X points" under existing customers is a trust regression.
7. **PolicyCap is held inside `Merchant`** for future controlled policy migration, but **no runtime adjustment entry is exposed in v1**. Soulbound is permanent.
8. **Payment verification is events-only** — port of Solana Pay's `reference` pattern. `PaymentEvent { merchant_id, order_ref, customer, amount, loyalty_minted, timestamp_ms }`. Indexer subscribes by `merchant_id`, resolves `order_ref → settled?`. No on-chain `PaymentIntent` object.
9. **Redemption Hold is a shared object carrying `Balance<LOYALTY>`** extracted from the customer's PAS Account via `unlock_funds::resolve`. Hash-commit-reveal binds an off-chain `code` to `sha3_256(code)`. `release` is permissionless after expiry; balance returns to the original customer's account.
10. **Lazy in-payment Account creation** for first-time customers — frontend's PTB step 0 calls `account::create_and_share(&mut namespace, customer)` if the customer's loyalty Account doesn't exist. Permissionless in PAS. Contention bounded to first-time customers.
11. **Loyalty asset is a standard Sui Coin (decimals 0)** wrapped with `Policy<Balance<LOYALTY>>` that registers approvals only for `unlock_funds` — `send_funds` and `clawback_funds` have no approvals → soulbound, no clawback.
12. **Generic over stablecoin type `S`** in `payment::pay<S>` — customer's PTB pre-approves the stablecoin issuer's `TransferApproval` before calling our entry. Production deployments instantiate `S` to a real PAS-issued stablecoin (e.g. S3 / S3.MONEY).

### Public API surface

| Module | Function | Visibility | Purpose |
|---|---|---|---|
| loyalty | `init(otw, ctx)` | private (auto-called) | Create currency + freeze metadata |
| loyalty | `setup(namespace, cap, ctx) -> Loyalty` | public | Create Policy, register approvals, bundle outputs |
| loyalty | `destruct(loyalty) -> (TreasuryCap, PolicyCap, ID)` | pkg | Consumed by `merchant::create_merchant` |
| loyalty | `mint_into(cap, account, amount)` | pkg | Called by `payment::pay` |
| loyalty | `new_redeem_unlock_approval() -> RedeemUnlockApproval` | pkg | Called by `redemption::request_redeem` |
| merchant | `create_merchant(loyalty, ...) -> MerchantCap` | public | Consume Loyalty, share Merchant |
| merchant | `name`, `logo_url`, `payout_address`, `loyalty_policy_id`, `mint_params`, `next_listing_id`, `listings_count`, `merchant_id` | public | Read-only getters |
| merchant | `set_payout_address`, `set_display` | public (cap-gated) | Mutable display + routing |
| merchant | `add_listing`, `set_listing_price`, `set_listing_name`, `set_listing_active`, `remove_listing`, `borrow_listing`, `contains_listing` | public (cap-gated for writes) | Listing CRUD |
| merchant | `assert_cap_matches` | public | Assertion helper used by other modules |
| merchant | `loyalty_treasury_cap_mut` | pkg | Borrow cap for mint/burn |
| listing | `listing_id`, `listing_name`, `listing_price`, `listing_active` | public | Accessors on `Listing` |
| listing | `new`, `set_price`, `set_name`, `set_active` | pkg | Mutators (only `merchant` calls) |
| payment | `pay<S>(merchant, request, policy_s, customer_loyalty_account, order_ref, clock, ctx)` | public | Atomic stablecoin spend + loyalty mint |
| redemption | `request_redeem(merchant, request, policy_loyalty, code_hash, ttl_ms, clock, ctx)` | public | Extract balance into Hold |
| redemption | `verify(merchant, cap, hold, code, clock)` | public (cap-gated) | Burn on preimage match |
| redemption | `release(hold, customer_loyalty_account, clock)` | public (permissionless after expiry) | Return balance |

### Object ownership model

| Object | Visibility | Lifetime | Module |
|---|---|---|---|
| `Merchant` | shared | permanent | merchant |
| `MerchantCap` | owned (`key, store`) | permanent | merchant |
| `Loyalty` | owned (`key`-only, no drop/store) | ephemeral (between bootstrap txs) | loyalty |
| `Policy<Balance<LOYALTY>>` | shared | permanent | loyalty (PAS-typed) |
| `CoinMetadata<LOYALTY>` | shared + frozen | permanent | loyalty (PAS-typed) |
| `Hold` | shared | short (minutes) | redemption |
| `Account<LOYALTY>` (per customer) | shared | per-customer | PAS (created via `account::create_and_share`) |
| `Account<S>` (customer + merchant) | shared | per-user | PAS (stablecoin namespace) |
| PAS `Namespace` | shared, singleton | permanent | PAS infrastructure |

### Events

- `merchant`: none in v1 (deferred — add `MerchantCreated`, `ListingAdded`, etc. when needed)
- `payment::PaymentEvent { merchant_id, order_ref, customer, amount, loyalty_minted, timestamp_ms }`
- `redemption::RedeemRequested { hold_id, merchant_id, customer, amount, expires_at_ms }`
- `redemption::RedemptionVerified { hold_id, merchant_id, customer, amount }`
- `redemption::RedemptionReleased { hold_id, merchant_id, customer, amount }`

### Error constants

All modules use the new `#[error(code = N)] const E... : vector<u8> = b"...";` attribute pattern (vs legacy `const E... : u64 = N;`), matching PAS convention. Specific lists:

- **merchant**: `EWrongMerchantCap (0)`, `EEmptyName (1)`, `EZeroMintDenominator (2)`, `EListingNotFound (3)`
- **listing**: `EEmptyName (0)`, `EZeroPrice (1)`
- **payment**: `EWrongRecipient (0)`, `EWrongLoyaltyRecipient (1)`
- **redemption**: `EEmptyCodeHash (0)`, `EZeroTtl (1)`, `EZeroAmount (2)`, `EWrongMerchantForHold (3)`, `EExpired (4)`, `ENotExpired (5)`, `EWrongCode (6)`, `EWrongCustomer (7)`

## Invariant Enforcement Map

### Type-level (enforced by struct definitions / abilities)

| Invariant | Enforcement Location | Mechanism |
|---|---|---|
| INV-1 Loyalty bundle must be consumed | `loyalty::Loyalty` | `has key` only — no `drop`, `store`, `copy` |
| INV-2 MerchantCap is transferable | `merchant::MerchantCap` | `has key, store` |
| INV-3 Hold cannot be silently dropped | `redemption::Hold` | `has key` only |
| INV-4 Loyalty is soulbound | `loyalty::setup` | No `send_funds` approval registered |
| INV-5 No clawback | `loyalty::setup` | `clawback_allowed = false` + no `clawback_funds` approval |
| INV-6 Only redemption can unlock loyalty | `loyalty::setup` + `new_redeem_unlock_approval` | Approval witness constructor is `public(package)` |
| INV-7 External packages cannot mint LOYALTY | `loyalty::mint_into` | `public(package)` only |

### Runtime (assert! statements)

| Invariant | Enforcement Location | Error |
|---|---|---|
| INV-8 MerchantCap must match Merchant | `merchant::assert_cap_matches` (called by all cap-gated entries) | `EWrongMerchantCap` |
| INV-9 Merchant name non-empty | `merchant::create_merchant`, `set_display` | `EEmptyName` |
| INV-10 Mint denominator non-zero | `merchant::create_merchant` | `EZeroMintDenominator` |
| INV-11 Listing name non-empty | `listing::new`, `listing::set_name` | `EEmptyName` |
| INV-12 Listing price non-zero | `listing::new`, `listing::set_price` | `EZeroPrice` |
| INV-13 Listing must exist before mutating | `merchant::set_listing_*`, `remove_listing`, `borrow_listing` | `EListingNotFound` |
| INV-14 Payment recipient matches merchant payout | `payment::pay` | `EWrongRecipient` |
| INV-15 Loyalty mints to payer's own account | `payment::pay` | `EWrongLoyaltyRecipient` |
| INV-16 Mint bounded by max | `payment::pay` | (clamp, not assert) |
| INV-17 No mint overflow | `payment::pay` | u128 intermediate |
| INV-18 Hold code_hash non-empty | `redemption::request_redeem` | `EEmptyCodeHash` |
| INV-19 Hold ttl > 0 | `redemption::request_redeem` | `EZeroTtl` |
| INV-20 Hold amount > 0 | `redemption::request_redeem` | `EZeroAmount` |
| INV-21 Verify before expiry | `redemption::verify` | `EExpired` |
| INV-22 Release after expiry | `redemption::release` | `ENotExpired` |
| INV-23 Code preimage matches commitment | `redemption::verify` | `EWrongCode` |
| INV-24 Verify only on Hold for this merchant | `redemption::verify` | `EWrongMerchantForHold` |
| INV-25 Release deposits only to original customer | `redemption::release` | `EWrongCustomer` |

## Implementation Notes

- **Burn API quirk:** `coin::burn_balance` does not exist in the Sui framework rev pinned (`c2428b3`). Used `balance::decrease_supply(coin::supply_mut(cap), funds)` instead. Documented inline.
- **Move 2024 method-call syntax** used throughout for readability (e.g. `merchant.payout_address()`, `clock.timestamp_ms()`, `id.delete()`). Resolves via first-arg type matching.
- **u128 intermediate** in `payment::pay`'s mint computation to dodge overflow when `payment_amount * mint_numerator` exceeds u64.
- **Snapshot-before-consume pattern** in `payment::pay` and `redemption::verify`: read all needed fields from request/hold *before* calling `resolve` or destructuring, then operate on the values.
- **`balance::decrease_supply` is the burn primitive** — `coin::burn` requires a Coin (not Balance) and a TxContext.
- **`hash::sha3_256` chosen** over Sui-native `blake2b256` for cross-platform compatibility (any client can compute the preimage hash trivially in JS, Python, etc.).
- **No events on merchant operations** (e.g. `MerchantCreated`, `ListingAdded`) in v1 — only payment/redemption flows emit events. Deferred until a clear indexer requirement emerges.
- **IDE spell-check / LSP noise** on domain terms (`soulbound`, `clawback`, `preimage`, `permissionless`, `Solana`, `Mysten`) and occasional stale `unused use` warnings — informational only; build is the source of truth.

## Out of Scope

- **Tests** — next stage (`/sui-tests`). No `*_tests.move` files yet.
- **Mock stablecoin implementation** — `stablecoin-mock/sources/stablecoin_mock.move` is still a stub. End-to-end testing needs it (mock PAS-issued asset with a permissionless TransferApproval).
- **Receipt NFTs** — deferred to v2 per dev spec; the `PaymentEvent` shape is extensible.
- **Confidential transfers, loyalty leaderboard, multiple custom attributes per listing** — deferred per dev spec.
- **Multi-merchant / marketplace support** — single-tenant template by design.
- **Real fiat off-ramp** — mock only; real integration is a separate workstream.
- **Real USDC integration** — USDC on Sui is Sui Coin, not PAS. Template is closed-loop / issuer-controlled stablecoin only.
- **On-chain replay protection for payments** — `order_ref` reuse is the indexer's responsibility.
- **Runtime mutation of mint policy params** — write-once at `create_merchant`. Future controlled migration would require a new function.
- **Runtime policy adjustment entry** — `PolicyCap` is held inside `Merchant` for future use; no entry exposes it in v1.
- **`withdraw_balance<S>` helper** — merchant withdraws via PAS directly (`account.send_balance` from their payout `Account<S>`).
- **Frontend / TS SDK** — out of scope for this Move-only stage.
- **Merchant events** (`MerchantCreated`, `ListingAdded`, etc.) — deferred.
- **`pause`/`unpause`** emergency stop — not in v1.
- **OZ AccessControl migration** — Sui-native capability pattern in v1; AccessControl is a future-stage concern when that library is released and audited.

## Dev Notes

- The design conversation produced renames mid-stream: `MerchantConfig → Merchant` (one shared object holds all merchant state, not just config); `LoyaltyBootstrap → Loyalty` (moved from `merchant.move` to `loyalty.move` with a `public(package) destruct` helper); `setup_loyalty → setup` (loyalty's module-level setup function); `Catalog` removed entirely (folded into `Merchant.listings`).
- PAS dep was originally a git URL pinned to commit `b64f0c5`. Switched to **vendored** at `vendor/pas/` because PAS doesn't declare a `test-publish` environment and we needed to add it locally (matches OZ AMM convention). `Move.lock` files now committed.
- The dep edition mismatch I worried about (`2024` vs `2024.beta`) turned out to be a non-issue: the original failure was actually `[addresses]` + `[environments]` conflicting in the same Move.toml. PAS new-style + ours new-style works fine.
- We skipped the standard pipeline order (research → design → invariants → code → tests → docs) by jumping from research directly to code-draft, with design + invariants merged into this artifact. Trade-off accepted by the dev; documented here so future skill invocations on this project know the artifact history is non-canonical.
- `.vscode/tasks.json` uses `--build-env test-publish` for build + test. Build commands in this artifact assume the same.

## Open Questions

1. **Mock stablecoin implementation** — what shape should the PAS Policy for the mock take? Permissionless TransferApproval (anyone can move) for dev ease? Or replicate the loyalty example's `RedeemApproval` pattern to demonstrate "stablecoin needs issuer approval" UX? Tests stage decides.
2. **Tests** — `/sui-tests` is the next skill. Target coverage: every runtime invariant + happy paths + the three Hold lifecycle outcomes (verify, release, double-spend abort).
3. **Pre-commit hook to strip `[pinned.test-publish.*]` from `Move.lock`** before commit (OZ AMM does this) — worth adopting before contributors land.
4. **Mock vs vendored PAS for future updates** — vendoring captures PAS at one commit. When PAS updates upstream we manually re-sync. Acceptable trade-off; documented in the README would help future contributors.
5. **Add events to merchant operations** if/when the dashboard indexer wants them (`MerchantCreated`, `ListingAdded { id, name, price }`, `MerchantPolicyChanged`, etc.). Defer until concrete need.
6. **`destroy_zero` defensive check?** If a Hold ends up with a zero balance somehow (shouldn't happen given INV-20), burn / release would behave fine but `balance::decrease_supply(0)` is wasted gas. Probably skip for v1 — INV-20 catches it upstream.
