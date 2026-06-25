/// Tests for `config.move` — `Config::new` invariant assertions.
#[test_only]
module openzeppelin_payments::config_tests;

use openzeppelin_payments::config;
use openzeppelin_payments::test_setup::{Self, TEST_USD};
use std::unit_test::destroy;

const PAYOUT: address = @0xB;

/// Drive a failure-path test through a real `Currency<TEST_USD>`. Each test
/// expects `config::new<TEST_USD>` to abort on the validation step under test;
/// the destroy calls are only reached on the (impossible) happy path.
macro fun expect_aborts($try: |&sui::coin_registry::Currency<TEST_USD>| -> config::Config) {
    let (currency, treasury) = test_setup::new_test_currency(1);
    let _ = $try(&currency);
    destroy(currency);
    destroy(treasury);
}

#[test, expected_failure(abort_code = config::EZeroInvoiceTtl)]
fun config_zero_invoice_ttl_aborts() {
    expect_aborts!(
        |c| config::new<TEST_USD>(
            c,
            PAYOUT,
            config::loyalty_float_scaling(),
            1_000_000,
            0,
            600_000,
        ),
    );
}

#[test, expected_failure(abort_code = config::EZeroVoucherTtl)]
fun config_zero_voucher_ttl_aborts() {
    expect_aborts!(
        |c| config::new<TEST_USD>(
            c,
            PAYOUT,
            config::loyalty_float_scaling(),
            1_000_000,
            600_000,
            0,
        ),
    );
}

#[test, expected_failure(abort_code = config::ETtlTooLarge)]
fun config_invoice_ttl_too_large_aborts() {
    // 1e18 ms ≫ MAX_TTL_MS (7 days) — aborts.
    expect_aborts!(
        |c| config::new<TEST_USD>(
            c,
            PAYOUT,
            config::loyalty_float_scaling(),
            1_000_000,
            1_000_000_000_000_000_000,
            600_000,
        ),
    );
}

#[test, expected_failure(abort_code = config::ETtlTooLarge)]
fun config_voucher_ttl_too_large_aborts() {
    expect_aborts!(
        |c| config::new<TEST_USD>(
            c,
            PAYOUT,
            config::loyalty_float_scaling(),
            1_000_000,
            600_000,
            1_000_000_000_000_000_000,
        ),
    );
}
