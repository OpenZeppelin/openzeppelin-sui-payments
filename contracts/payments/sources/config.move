/// Merchant configuration. Owned by `Merchant` and consumed by `payment` and
/// `redemption` for two purposes:
///
/// 1. Loyalty mint rate per payment:
///        `loyalty = (payment_units * mint_numerator) / mint_denominator`
///    capped at `max_mint_per_payment`.
/// 2. Lifetimes applied to issued invoices and customer-issued vouchers:
///        `invoice.expires_at_ms  = clock + invoice_ttl_ms`
///        `voucher.expires_at_ms  = clock + voucher_ttl_ms`
///
/// Updated via `merchant::set_config`.
module openzeppelin_payments::config;

// === Errors ===

#[error(code = 0)]
const EZeroMintDenominator: vector<u8> = "Mint denominator cannot be zero";
#[error(code = 1)]
const EZeroInvoiceTtl: vector<u8> = "invoice_ttl_ms must be greater than zero";
#[error(code = 2)]
const EZeroVoucherTtl: vector<u8> = "voucher_ttl_ms must be greater than zero";

// === Structs ===

/// Loyalty mint + expiry configuration for a merchant.
public struct Config has drop, store {
    /// Numerator of the mint ratio.
    mint_numerator: u64,
    /// Denominator of the mint ratio. Must be non-zero.
    mint_denominator: u64,
    /// Hard cap on minted LOYALTY per payment.
    max_mint_per_payment: u64,
    /// Lifetime in milliseconds applied to merchant-issued invoices
    /// (`invoice.expires_at_ms = clock + invoice_ttl_ms`). Must be > 0.
    invoice_ttl_ms: u64,
    /// Lifetime in milliseconds applied to customer-issued vouchers
    /// (`voucher.expires_at_ms = clock + voucher_ttl_ms`). Must be > 0.
    voucher_ttl_ms: u64,
}

// === Public Functions ===

/// Construct a new `Config`. `mint_denominator`, `invoice_ttl_ms`, and
/// `voucher_ttl_ms` must all be non-zero; `mint_numerator = 0` and/or
/// `max_mint_per_payment = 0` are permitted (loyalty mint becomes a no-op).
/// Pass the returned value to `merchant::create` (initial setup) or
/// `merchant::set_config` (replacement).
public fun new(
    mint_numerator: u64,
    mint_denominator: u64,
    max_mint_per_payment: u64,
    invoice_ttl_ms: u64,
    voucher_ttl_ms: u64,
): Config {
    assert!(mint_denominator != 0, EZeroMintDenominator);
    assert!(invoice_ttl_ms > 0, EZeroInvoiceTtl);
    assert!(voucher_ttl_ms > 0, EZeroVoucherTtl);

    Config {
        mint_numerator,
        mint_denominator,
        max_mint_per_payment,
        invoice_ttl_ms,
        voucher_ttl_ms,
    }
}

/// Compute the loyalty amount earned on a `payment_amount` under this config:
///
///     `loyalty = min(payment_amount * mint_numerator / mint_denominator, max_mint_per_payment)`
public fun compute_loyalty(self: &Config, payment_amount: u64): u64 {
    payment_amount
        .mul_div(self.mint_numerator, self.mint_denominator)
        .min(self.max_mint_per_payment)
}

// === View Functions ===

/// Numerator of the mint ratio.
public fun mint_numerator(self: &Config): u64 { self.mint_numerator }

/// Denominator of the mint ratio.
public fun mint_denominator(self: &Config): u64 { self.mint_denominator }

/// Hard cap on minted LOYALTY per payment.
public fun max_mint_per_payment(self: &Config): u64 { self.max_mint_per_payment }

/// Lifetime (ms) applied to merchant-issued invoices.
public fun invoice_ttl_ms(self: &Config): u64 { self.invoice_ttl_ms }

/// Lifetime (ms) applied to customer-issued vouchers.
public fun voucher_ttl_ms(self: &Config): u64 { self.voucher_ttl_ms }
