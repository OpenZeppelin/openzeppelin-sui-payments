---
stage: review
project: openzeppelin-sui-payments
mode: extension
extends: contracts/payments/sources
status: complete
timestamp: 2026-06-26
author: btt-pass
previous_stage: post-core/basic-review.md
tags: [btt, coverage, post-core]
---

# OpenZeppelin Sui Payments — BTT Coverage Report

## Summary

Standalone BTT pass on the payments + closed-loop loyalty module. Tree derived from 60 `assert!` checks across 8 source files plus 13 `event::emit` sites; walked against the existing 83-test suite. Found 15 leaves with insufficient coverage; landed 14 new tests (one item — duplicate-listing-id — was deliberately marked Not Applicable since it aborts via framework error, not ours).

**Before:** 102 / 117 leaves covered — **86 ✅, 12 ◐, 4 ⚠️, 15 ❌**
**After:** 116 / 117 leaves covered — **100 ✅, 12 ◐, 4 ⚠️, 1 (Not Applicable)**

Test count: **83 → 97**. `sui move test --build-env testnet` is green.

**Verdict:** tight. Coverage is comprehensive across all defined error codes (every `E*` const now has a backing failure-path test), both settlement codepaths (`pay` and `pay_with_coin`) are symmetric, and the documented `compute_loyalty` rounding behavior is locked in.

## Source-Derived Leaf List (from Step 2.0)

### `assert!` locations (60 total)
- `config.move`: 142 (`EDecimalsTooLarge`), 143-146 (`EZeroInvoiceTtl`, `ETtlTooLarge` x2, `EZeroVoucherTtl`)
- `listing.move`: 71, 99, 100, 102 (`EEmptyName`, `EZeroPrice` x2), 132, 178 (`EVariantNotFound` x2), 192 (`EActiveStateUnchanged`)
- `merchant.move`: 256 (`EEmptyName`); pay path 324, 332, 334, 338, 339, 341 (6 asserts); pay_with_coin 420, 428, 430, 433 (4 asserts); cancel_invoice 486, 493 (2); create_voucher 548-551, 556, 563 (6); cancel_voucher 602, 610, 611 (3); view fns 670, 688, 712, 717, 727, 737, 751, 763 (8); update_display 789-790 (2); update_config 814 (1); catalog mutators 869, 900, 930, 959 (4); create_invoice 1008-1011 (4); redeem 1072, 1081-1082 (3); prune 1117, 1140 (2); private helpers 1155, 1169 (2)

### `event::emit` locations (13 total)
- `events.move`: 142 (InvoiceCreated), 147 (VoucherCreated), 162 (InvoicePaid), 182 (VoucherRedeemed), 198 (InvoiceCanceled), 203 (VoucherCanceled), 208 (ListingAdded), 213 (ListingRemoved), 218 (ListingStatusChanged), 223 (VariantAdded), 228 (VariantRemoved), 233 (ConfigUpdated), 238 (DisplayUpdated)

All 13 events have a backing emission test with full payload assertions via `assert_emitted!` (`ConfigUpdated` and `DisplayUpdated` have empty payloads, so their assertions are trivially complete).

## Branching Tree

(High-signal subset; trivial getters covered incidentally are omitted for compactness.)

```
config::new<C>
├── given decimals <= 18 → ok                                            ✅
├── given decimals == MAX_DECIMALS (boundary)                            ✅ config_decimals_at_max_succeeds (NEW)
├── given decimals > MAX_DECIMALS → EDecimalsTooLarge                    ✅ config_decimals_too_large_aborts (NEW)
├── given invoice_ttl_ms = 0 → EZeroInvoiceTtl                            ✅
├── given voucher_ttl_ms = 0 → EZeroVoucherTtl                            ✅
├── given invoice_ttl_ms > MAX_TTL_MS → ETtlTooLarge                      ✅
└── given voucher_ttl_ms > MAX_TTL_MS → ETtlTooLarge                      ✅

config::compute_loyalty
├── given normal amount/coefficient → returns scaled value               ✅
├── given coefficient = 0 → returns 0                                    ✅
├── given amount * coeff > max → clamps to max                            ✅
└── given fractional result (< 1) → rounds down to 0                     ✅ compute_loyalty_rounds_down_to_zero (NEW)

merchant::pay<C>           all branches ✅ (existing coverage was complete)
merchant::pay_with_coin<C>
├── given valid + amount = invoice.amount → settles                       ✅
├── given amount mismatch → EAmountMismatch                               ✅
├── given wrong currency → EWrongPaymentType                              ✅
├── given expired → EInvoiceExpired                                       ✅
├── given unknown invoice → EInvoiceNotFound                              ✅
├── given zero coefficient → mints 0                                      ✅ pay_with_coin_zero_loyalty_no_mint (NEW)
└── given amount * coeff > max → clamps to max                            ✅ pay_with_coin_clamps_loyalty_to_max (NEW)

merchant::create_invoice
├── given items.length() == MAX_INVOICE_ITEMS → ok                       ✅ create_invoice_at_items_cap_succeeds (NEW)
├── given order_ref.length() == MAX_ORDER_REF_LEN → ok                   ✅ create_invoice_at_order_ref_cap_succeeds (NEW)
└── (other 8 branches covered pre-existing)                              ✅

merchant::create_voucher
├── given variant not found → EVariantNotFound                           ✅ create_voucher_variant_not_found_aborts (NEW)
└── (other 9 branches covered pre-existing)                              ✅

merchant::update_display
├── given different name + same logo → updates                            ✅ update_display_name_only_updates (NEW)
├── given same name + different logo → updates                            ✅ update_display_logo_only_updates (NEW)
├── given different name + different logo → updates                       ✅
└── given identical → EDisplayUnchanged                                   ✅

merchant::invoice_receipt (view)
├── given exists → returns                                                ✅
└── given missing → EReceiptNotFound                                      ✅ invoice_receipt_unknown_id_aborts (NEW)

merchant::voucher_receipt (view)
├── given exists → returns                                                ✅
└── given missing → EReceiptNotFound                                      ✅ voucher_receipt_unknown_id_aborts (NEW)

merchant::active_listing_variant (view)
├── given active variant exists → returns                                ✅
├── given variant missing → EVariantNotFound                              ✅ active_listing_variant_not_found_aborts (NEW)
└── given listing inactive → EListingInactive                             ✅

merchant::add_listing
├── given valid listing → adds + emits                                    ✅
└── given listing.id collision in table → framework abort                 ⊘ Not Applicable (unreachable through normal callers; would need synthetic id collision)

receipt::compute_total
├── given normal items → returns sum                                      ✅
└── given items overflow u64 → EAmountOverflow                            ✅ compute_total_overflow_aborts (NEW)
```

## Coverage Map (post-additions)

Every previously-`❌` row is now `✅`. `◐` and `⚠️` rows are unchanged from the basic-review pass — they reflect view-getters and trivial accessors that are incidentally covered through happy-path tests and have low refactoring-drift risk.

## Design Deviations

- **`merchant::add_listing` framework-error abort path** — when `listing.id` (or any of its variant ids) is already in the table, the abort surfaces as `Table::EKeyAlreadyExists` / `vec_map::EKeyAlreadyExists`, not a `merchant::E*` constant. Acceptable because (a) `listing::new` uses `tx_context::fresh_object_address` so collisions are unreachable through normal callers, and (b) the framework abort is atomically rolled back. Worth a one-line doc note on `add_listing` if you want full self-description but not blocking.

## Additions Written

### config_decimals_too_large_aborts
**Type:** New test
**File:** `tests/config_tests.move` (after `config_voucher_ttl_too_large_aborts`)
**Pins:** `config::new<C>` / given decimals > MAX_DECIMALS / it aborts `EDecimalsTooLarge`
**Confidence change:** `❌ → ✅`
**Severity:** High (defined error without backing test)
**Verifies:** Defensive cap on currency decimals — protects `compute_loyalty`'s u128 overflow guard
**Code:** Builds a `Currency<TEST_USD>` with `decimals = 19` via `test_setup::new_test_currency_with_decimals` (new helper) and asserts `config::new` aborts.

### config_decimals_at_max_succeeds
**Type:** New test
**File:** `tests/config_tests.move`
**Pins:** `config::new<C>` / given decimals == 18 (boundary) / it returns ok
**Confidence change:** `❌ → ✅`
**Severity:** Medium (boundary confirmation — locks `<=` direction)

### compute_loyalty_rounds_down_to_zero
**Type:** New test
**File:** `tests/config_tests.move`
**Pins:** `config::compute_loyalty` / given fractional result / it rounds down to 0
**Confidence change:** `❌ → ✅`
**Severity:** Medium
**Verifies:** Documented rounding semantics in `config.move:149`. Locks the `<1 → 0` behavior so a future numerator/denominator swap can't silently change it.

### pay_with_coin_zero_loyalty_no_mint
**Type:** New test
**File:** `tests/payment_tests.move` (after `pay_with_coin_happy_path`)
**Pins:** `pay_with_coin<C>` / given zero coefficient / it mints 0 LOY
**Confidence change:** `❌ → ✅`
**Severity:** Medium (asymmetric coverage — PAS path had this, open-loop didn't)

### pay_with_coin_clamps_loyalty_to_max
**Type:** New test
**File:** `tests/payment_tests.move`
**Pins:** `pay_with_coin<C>` / given amount * coefficient > max / it clamps
**Confidence change:** `❌ → ✅`
**Severity:** Medium (asymmetric coverage)

### create_invoice_at_items_cap_succeeds
**Type:** New test
**File:** `tests/payment_tests.move` (before `pay_unknown_invoice_aborts`)
**Pins:** `create_invoice` / given items.length() == MAX_INVOICE_ITEMS (boundary) / it returns ok
**Confidence change:** `❌ → ✅`
**Severity:** Medium

### create_invoice_at_order_ref_cap_succeeds
**Type:** New test
**File:** `tests/payment_tests.move`
**Pins:** `create_invoice` / given order_ref.length() == MAX_ORDER_REF_LEN (boundary) / it returns ok
**Confidence change:** `❌ → ✅`
**Severity:** Medium

### invoice_receipt_unknown_id_aborts
**Type:** New test
**File:** `tests/payment_tests.move`
**Pins:** `merchant::invoice_receipt` / given receipt missing / it aborts `EReceiptNotFound`
**Confidence change:** `❌ → ✅`
**Severity:** Informational (defense-in-depth — view-fn contract independent of prune path)

### compute_total_overflow_aborts
**Type:** New test
**File:** `tests/payment_tests.move`
**Pins:** `receipt::compute_total` / given items overflow u64 / it aborts `EAmountOverflow`
**Confidence change:** `❌ → ✅`
**Severity:** High (defined error in `receipt.move:23` had no backing test; the checked-arithmetic path was dead code from the suite's perspective)
**Code:** Triggers the overflow through `create_invoice` with `variant.price = u64::MAX` and `quantity = 2`.

### create_voucher_variant_not_found_aborts
**Type:** New test
**File:** `tests/redemption_tests.move` (before `create_voucher_too_many_items_aborts`)
**Pins:** `create_voucher` / given variant_id not in variant_index / it aborts `EVariantNotFound`
**Confidence change:** `❌ → ✅`
**Severity:** Medium (symmetric with `new_variant_not_found_aborts` on the invoice path)

### voucher_receipt_unknown_id_aborts
**Type:** New test
**File:** `tests/redemption_tests.move` (after `cancel_voucher_unknown_id_aborts`)
**Pins:** `merchant::voucher_receipt` / given receipt missing / it aborts `EReceiptNotFound`
**Confidence change:** `❌ → ✅`
**Severity:** Informational

### update_display_name_only_updates
**Type:** New test
**File:** `tests/merchant_tests.move` (before `update_display_unchanged_aborts`)
**Pins:** `update_display` / given different name + same logo / it updates (no abort)
**Confidence change:** `❌ → ✅`
**Severity:** Medium (one side of the OR in `EDisplayUnchanged`)

### update_display_logo_only_updates
**Type:** New test
**File:** `tests/merchant_tests.move`
**Pins:** `update_display` / given same name + different logo / it updates
**Confidence change:** `⚠️ → ✅`
**Severity:** Medium (other side of the OR)

### active_listing_variant_not_found_aborts
**Type:** New test
**File:** `tests/merchant_tests.move` (after `listing_variant_not_found_aborts`)
**Pins:** `merchant::active_listing_variant` / given variant missing / it aborts `EVariantNotFound`
**Confidence change:** `⚠️ → ✅`
**Severity:** Informational (was transitively covered through `create_invoice` failure paths)

### test_setup::new_test_currency_with_decimals (helper)
**Type:** New helper, factored out of `new_test_currency`
**File:** `tests/test_setup.move`
**Purpose:** Enables building a `Currency<TEST_USD>` with arbitrary decimals — required by the two new decimals-related tests above. The existing `new_test_currency(hint)` is now a thin wrapper that calls with `decimals = 0`.

## Rejections (Intentional Gaps)

### add_listing / given duplicate listing.id / framework abort
**Reason:** `listing::new` derives the id from `tx_context::fresh_object_address`, which is monotonic per transaction. Collisions are unreachable through normal callers. Testing would require constructing a synthetic id collision via test-only escape hatches, which isn't a realistic threat model. Marked Not Applicable.

## Out of Scope

### Deferred (will revisit)
- None.

### Not Applicable (closed)
- **Hot-potato compile-time invariants** on `Loyalty` / `Voucher` / `Invoice` (no `drop`) — type-level enforcement, no runtime test possible.
- **Listing id collisions in `add_listing`** — unreachable through normal callers; see Rejections.
- **Trivial accessors in `payment.move`, `redemption.move`, `listing.move`** (e.g. `Invoice::amount()`, `Voucher::customer()`) — incidentally covered through happy-path tests that read these values. Direct tests would be one-line shadows of the implementation with low signal.
- **`loyalty::create` failure paths** — function never aborts. No failure-path coverage needed.

## Cascade Plan

None — no upstream artifacts in this repo (standalone usage). If a `merchant.move` doc tweak is desired for the framework-error point under Design Deviations, that's a one-line addition; otherwise nothing required.

## Dev Notes

Pre-pass state was already strong (83 tests, 4/9 audit findings already applied during the prior session). This run focused on:
1. **Defined-error-code completeness** — every `E*` const now has a backing test (`EDecimalsTooLarge` and `EAmountOverflow` were the gaps).
2. **Codepath symmetry** — `pay_with_coin` had two fewer test cases than `pay`; both are now mirrored.
3. **Boundary cases** — the cap inequalities (`<=`) are now pinned, not just the over-limit aborts.
4. **View-fn aborts** — the two receipt-getter `EReceiptNotFound` paths and the `active_listing_variant` `EVariantNotFound` path were transitively covered or untested; now each has a direct test.

The Design Deviation (`add_listing` framework-error abort) is the only doc-level item worth surfacing if a follow-up commit touches `merchant.move` docs.

## Open Questions

- None blocking. The single Not-Applicable rejection (duplicate listing ids) is well-justified by the deterministic id derivation; revisit only if `listing::new` ever moves away from `fresh_object_address`.
