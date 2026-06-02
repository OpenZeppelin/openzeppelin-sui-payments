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
