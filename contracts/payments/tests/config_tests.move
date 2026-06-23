/// Tests for `config.move` — `Config::new` invariant assertions.
#[test_only]
module openzeppelin_payments::config_tests;

use openzeppelin_payments::config;

#[test, expected_failure(abort_code = config::EZeroMintDenominator)]
fun config_zero_mint_denominator_aborts() {
    let _ = config::new(1, 0, 1_000_000, 600_000, 600_000);
}

#[test, expected_failure(abort_code = config::EZeroInvoiceTtl)]
fun config_zero_invoice_ttl_aborts() {
    let _ = config::new(1, 10, 1_000_000, 0, 600_000);
}

#[test, expected_failure(abort_code = config::EZeroVoucherTtl)]
fun config_zero_voucher_ttl_aborts() {
    let _ = config::new(1, 10, 1_000_000, 600_000, 0);
}

#[test, expected_failure(abort_code = config::ETtlTooLarge)]
fun config_invoice_ttl_too_large_aborts() {
    // 1e18 ms ≫ MAX_TTL_MS (~10 years) — aborts.
    let _ = config::new(1, 10, 1_000_000, 1_000_000_000_000_000_000, 600_000);
}

#[test, expected_failure(abort_code = config::ETtlTooLarge)]
fun config_voucher_ttl_too_large_aborts() {
    let _ = config::new(1, 10, 1_000_000, 600_000, 1_000_000_000_000_000_000);
}
