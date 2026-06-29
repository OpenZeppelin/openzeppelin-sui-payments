/// Merchant configuration. Owned by `Merchant` and the single source of truth
/// for everything that differs between merchants:
///
/// - **Settlement identity**: `payout_address` (where stablecoin lands) and
///   `accepted_payment_type` (a `TypeName` snapshot used at runtime to reject
///   `pay<C>` calls in the wrong currency).
/// - **Decimals**: `payment_decimals` is read once from `&Currency<C>` at
///   `config::new<C>` time. Stored on the Config so `compute_loyalty` doesn't
///   have to round-trip through the `CoinRegistry` on every invoice, and so the
///   accepted currency is identified by `(TypeName, decimals)` together.
/// - **Loyalty mint rate**: a single fixed-point `loyalty_coefficient` where
///   `LOYALTY_FLOAT_SCALING (= 1e9)` represents `1.0 LOY per human unit`. The UI
///   exposes this as a decimal (`1.0`, `0.5`, `2.0`); the contract stores the raw
///   scaled integer. Decimals-aware:
///       `loyalty = (payment_units * loyalty_coefficient) / (LOYALTY_FLOAT_SCALING * 10^payment_decimals)`
///   capped at `max_loyalty_per_payment`. So "1 LOY per $1" -> `loyalty_coefficient = 1e9`
///   regardless of the coin's decimals.
/// - **TTLs** applied to issued invoices and customer-issued vouchers:
///       `invoice.expires_at_ms = clock + invoice_ttl_ms`
///       `voucher.expires_at_ms = clock + voucher_ttl_ms`
///
/// Updated atomically via `merchant::update_config(new: Config)`. There are no
/// targeted setters: rotating the payout address, swapping the loyalty rate, or
/// changing the accepted currency all happen via a fresh `Config` constructed
/// with `config::new<C'>` for the new `C'`.
module openzeppelin_payments::config;

use std::type_name::{Self, TypeName};
use sui::coin_registry::Currency;

// === Errors ===

#[error(code = 0)]
const EZeroInvoiceTtl: vector<u8> = "invoice_ttl_ms must be greater than zero";
#[error(code = 1)]
const EZeroVoucherTtl: vector<u8> = "voucher_ttl_ms must be greater than zero";
#[error(code = 2)]
const ETtlTooLarge: vector<u8> = "TTL exceeds the maximum allowed (MAX_TTL_MS)";
#[error(code = 3)]
const EDecimalsTooLarge: vector<u8> = "Currency decimals must be no greater than 18";

// === Constants ===

/// Upper bound (ms) on invoice/voucher TTLs - 7 days. Bounds how long an
/// open invoice or voucher can keep merchant state / customer-locked LOY
/// stuck, while still covering realistic POS flows (point-of-sale checkouts
/// complete in minutes; pay-this-bill links typically resolve within hours
/// to a few days). Doubles as a `u64`-overflow guard on the issuance-time
/// `clock.timestamp_ms() + ttl_ms` computation.
const MAX_TTL_MS: u64 = 7 * 24 * 60 * 60 * 1000;

/// Hard cap on currency decimals. `10^18` still fits in u64; anything bigger
/// would make the scale factor in `compute_loyalty` overflow u128 in pathological
/// combinations with `loyalty_coefficient`.
const MAX_DECIMALS: u8 = 18;

/// Fixed-point scale for `loyalty_coefficient`. A raw value of
/// `LOYALTY_FLOAT_SCALING` represents the decimal `1.0` (i.e. "1 LOY per human
/// payment unit"); `LOYALTY_FLOAT_SCALING / 2` represents `0.5`, etc. The UI
/// exposes this as a decimal and scales by this constant before submission.
const LOYALTY_FLOAT_SCALING: u64 = 1_000_000_000;

// === Structs ===

/// Merchant configuration. The accepted stablecoin currency `C` is captured by
/// `accepted_payment_type` (snapshotted from `type_name::with_defining_ids<C>()`
/// at `config::new<C>` time).
public struct Config has drop, store {
    /// Address that receives customer stablecoin payments. Snapshotted into each
    /// `Invoice` at `create_invoice` time, so changing this mid-flight does not
    /// affect open invoices.
    payout_address: address,
    /// `TypeName` of `C` - used at runtime to reject `pay<C'>` calls with a
    /// non-matching currency. Off-chain readers can identify the accepted
    /// currency from this without parsing type tags from BCS.
    accepted_payment_type: TypeName,
    /// Decimals of `C`, read from `&Currency<C>` at `config::new`. Used to
    /// normalize `payment_amount` into "human units" inside `compute_loyalty`.
    payment_decimals: u8,
    /// Fixed-point loyalty mint coefficient. Raw u64 scaled by
    /// `LOYALTY_FLOAT_SCALING` (1e9): a value of `LOYALTY_FLOAT_SCALING` means
    /// "1 LOY per human payment unit". `0` disables loyalty mint.
    loyalty_coefficient: u64,
    /// Hard cap on minted LOYALTY per payment. `compute_loyalty` clamps to this.
    max_loyalty_per_payment: u64,
    /// Lifetime (ms) applied to merchant-issued invoices. Must be non-zero.
    invoice_ttl_ms: u64,
    /// Lifetime (ms) applied to customer-issued vouchers. Must be non-zero.
    voucher_ttl_ms: u64,
}

// === Public Functions ===

/// Construct a new `Config`.
///
/// Reads `decimals` from `&Currency<C>` and pins `accepted_payment_type` to
/// `type_name::with_defining_ids<C>()`, so the config is internally consistent
/// with `C` regardless of what the caller might claim.
///
/// `loyalty_coefficient = 0` and/or `max_loyalty_per_payment = 0` are permitted -
/// loyalty mint becomes a no-op. Pass the returned value to `merchant::create<C>`
/// (initial setup) or `merchant::update_config` (replacement).
///
/// Note for merchants: this config is the live source for *future* invoices
/// only. Each issued `Invoice` snapshots `payout_address`, `payment_type`,
/// item prices, `amount`, and `loyalty` at creation time and is binding - a
/// later `update_config` does not retro-mutate open invoices. See
/// `payment::Invoice` for the full snapshot semantics.
///
/// #### Generics
/// - `C`: The stablecoin currency this merchant accepts.
///
/// #### Parameters
/// - `currency`: The `Currency<C>` shared object - only its `decimals()` is read.
/// - `payout_address`: Address that receives customer stablecoin on settlement.
///   MUST be an externally-owned account address, not an object ID. On Sui,
///   addresses and object IDs share one 32-byte space and cannot be
///   distinguished on-chain, so this is the admin's responsibility: pointing
///   payouts at an object ID makes settlements transfer-to-object, where funds
///   may be unrecoverable or receivable by an unintended party.
/// - `loyalty_coefficient`: Mint rate as a fixed-point u64 scaled by
///   `LOYALTY_FLOAT_SCALING` (1e9). `LOYALTY_FLOAT_SCALING` == "1 LOY per
///   human unit"; `0` disables loyalty mint.
/// - `max_loyalty_per_payment`: Hard cap on minted LOYALTY per payment.
/// - `invoice_ttl_ms`: Invoice lifetime in milliseconds. Must be in `(0, MAX_TTL_MS]`.
/// - `voucher_ttl_ms`: Voucher lifetime in milliseconds. Must be in `(0, MAX_TTL_MS]`.
///
/// #### Aborts
/// - `EDecimalsTooLarge` if `currency.decimals() > MAX_DECIMALS`.
/// - `EZeroInvoiceTtl` if `invoice_ttl_ms` is zero.
/// - `EZeroVoucherTtl` if `voucher_ttl_ms` is zero.
/// - `ETtlTooLarge` if either TTL exceeds `MAX_TTL_MS`.
public fun new<C>(
    currency: &Currency<C>,
    payout_address: address,
    loyalty_coefficient: u64,
    max_loyalty_per_payment: u64,
    invoice_ttl_ms: u64,
    voucher_ttl_ms: u64,
): Config {
    let payment_decimals = currency.decimals();
    assert!(payment_decimals <= MAX_DECIMALS, EDecimalsTooLarge);
    assert!(invoice_ttl_ms > 0, EZeroInvoiceTtl);
    assert!(invoice_ttl_ms <= MAX_TTL_MS, ETtlTooLarge);
    assert!(voucher_ttl_ms > 0, EZeroVoucherTtl);
    assert!(voucher_ttl_ms <= MAX_TTL_MS, ETtlTooLarge);

    Config {
        payout_address,
        accepted_payment_type: type_name::with_defining_ids<C>(),
        payment_decimals,
        loyalty_coefficient,
        max_loyalty_per_payment,
        invoice_ttl_ms,
        voucher_ttl_ms,
    }
}

/// Compute the loyalty amount earned on a `payment_amount` under this config.
///
/// `loyalty = min(payment_amount * coefficient / (LOYALTY_FLOAT_SCALING * 10^decimals), max)`,
/// rounding down. Done in u128 internally to avoid intermediate overflow.
///
/// NOTE: integer division rounds the fractional remainder away. Payments whose
/// `loyalty < 1` round down to `0` - small purchases at low coefficients earn
/// nothing on chain. If the result exceeds `max_loyalty_per_payment` it is clamped
/// rather than aborting.
///
/// E.g (assuming `payment_decimals = 6` - USDC - and a large enough `max`):
///     `coefficient = LOYALTY_FLOAT_SCALING` (1e9, "1.0"), `payment_amount = 1_000_000` ($1)
///          -> `loyalty = 1`.
///     `coefficient = LOYALTY_FLOAT_SCALING / 2` (5e8, "0.5"), `payment_amount = 2_000_000` ($2)
///          -> `loyalty = 1`.
///     `coefficient = LOYALTY_FLOAT_SCALING / 2` (5e8, "0.5"), `payment_amount = 1_000_000` ($1)
///          -> `loyalty = 0` (rounded down from 0.5).
///     `coefficient = 2 * LOYALTY_FLOAT_SCALING` (2e9, "2.0"), `payment_amount = 1_000_000` ($1)
///          -> `loyalty = 2`.
///     `coefficient = 0` disables loyalty mint entirely (`loyalty = 0` for any payment).
///
/// #### Parameters
/// - `self`: The merchant's `Config` (read-only).
/// - `payment_amount`: Settled stablecoin amount in raw u64 units (matching
///   `self.payment_decimals`).
///
/// #### Returns
/// - The LOYALTY units to mint, clamped to `max_loyalty_per_payment`.
public fun compute_loyalty(self: &Config, payment_amount: u64): u64 {
    let scale = 10u128.pow(self.payment_decimals);

    // Should not overflow LOYALTY_FLOAT_SCALING < u64::max & scale < u64::max
    let denom = (LOYALTY_FLOAT_SCALING as u128) * scale;

    // Should not overflow amount < u64::max & coefficient < u64::max
    let amount = payment_amount as u128;
    let coefficient = self.loyalty_coefficient as u128;
    let value = (amount * coefficient) / denom;

    let max = self.max_loyalty_per_payment as u128;
    if (value > max) { max as u64 } else { value as u64 }
}

// === View Functions ===

/// Address that receives customer stablecoin payments on settlement.
public fun payout_address(self: &Config): address { self.payout_address }

/// `TypeName` of the accepted stablecoin currency `C`.
public fun accepted_payment_type(self: &Config): TypeName { self.accepted_payment_type }

/// Decimals of `C`, snapshotted from `&Currency<C>` at config construction.
public fun payment_decimals(self: &Config): u8 { self.payment_decimals }

/// Fixed-point loyalty coefficient, scaled by `LOYALTY_FLOAT_SCALING`.
public fun loyalty_coefficient(self: &Config): u64 { self.loyalty_coefficient }

/// The scaling factor that turns the raw u64 `loyalty_coefficient` into a
/// human decimal. UI should divide by this to display.
public fun loyalty_float_scaling(): u64 { LOYALTY_FLOAT_SCALING }

/// Hard cap on minted LOYALTY per payment.
public fun max_loyalty_per_payment(self: &Config): u64 { self.max_loyalty_per_payment }

/// Lifetime (ms) applied to merchant-issued invoices.
public fun invoice_ttl_ms(self: &Config): u64 { self.invoice_ttl_ms }

/// Lifetime (ms) applied to customer-issued vouchers.
public fun voucher_ttl_ms(self: &Config): u64 { self.voucher_ttl_ms }
