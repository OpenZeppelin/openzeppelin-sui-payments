/// Shared test scaffolding for `openzeppelin_payments` tests.
///
/// Wraps `pas::e2e::test_tx!` to also set up a `LOYALTY` policy (via
/// `loyalty::create`), a mock `TEST_USD` stablecoin policy with a permissive
/// approval witness, and a `Merchant` ready to be `take_shared` in the next tx.
#[test_only]
module openzeppelin_payments::test_setup;

use openzeppelin_payments::config;
use openzeppelin_payments::loyalty::{Self, LOYALTY};
use openzeppelin_payments::merchant::{Self, MerchantCap};
use pas::namespace::Namespace;
use pas::policy::{Self, Policy};
use pas::request::Request;
use pas::send_funds::SendFunds;
use std::unit_test::destroy;
use sui::balance::Balance;
use sui::coin::{Self, TreasuryCap};

// === Test types ===

/// Mock stablecoin used as the `S` parameter to `invoice::pay<S>` in tests.
public struct TEST_USD has drop {}

/// Permissive approval witness for the `TEST_USD` policy. Anyone can produce
/// one — devnet-style.
public struct TestUsdApproval() has drop;

/// Stamp the `TestUsdApproval` witness on a pending `send_funds` request.
/// Mirrors what `stablecoin_mock::approve_transfer` does for the real mock.
public fun approve_test_usd(request: &mut Request<SendFunds<Balance<TEST_USD>>>) {
    request.approve(TestUsdApproval());
}

// === Setup ===

/// Setup helpers expected to be called inside a `pas::e2e::test_tx!` body.
/// Creates `LOYALTY` and `TEST_USD` policies, builds a `Merchant` with sane
/// defaults, and shares it. Returns `(merchant_id, MerchantCap, TEST_USD TreasuryCap)`.
/// The TreasuryCap is needed by tests to mint balance into customer PAS accounts.
public fun setup_merchant(
    namespace: &mut Namespace,
    payout_address: address,
    ctx: &mut TxContext,
): (ID, MerchantCap, TreasuryCap<TEST_USD>) {
    // LOYALTY: create the policy + bundle in one call.
    let loyalty_cap = coin::create_treasury_cap_for_testing<LOYALTY>(ctx);
    let loyalty_bundle = loyalty::create(namespace, loyalty_cap);

    // TEST_USD: create policy with the permissive `TestUsdApproval` for send_funds.
    let mut test_usd_cap = coin::create_treasury_cap_for_testing<TEST_USD>(ctx);
    let (mut test_usd_policy, test_usd_policy_cap) = policy::new_for_currency(
        namespace,
        &mut test_usd_cap,
        false,
    );
    test_usd_policy.set_required_approval<_, TestUsdApproval>(
        &test_usd_policy_cap,
        b"send_funds".to_string(),
    );
    policy::share(test_usd_policy);
    destroy(test_usd_policy_cap);

    // Merchant config: 10% loyalty (1/10), cap 1_000_000, 10-minute TTLs.
    let cfg = config::new(1, 10, 1_000_000, 600_000, 600_000);

    let (merchant, cap) = merchant::create(
        loyalty_bundle,
        cfg,
        b"Test Shop".to_string(),
        std::option::none(),
        payout_address,
        ctx,
    );
    let merchant_id = object::id(&merchant);
    merchant::share(merchant);

    (merchant_id, cap, test_usd_cap)
}

/// Borrow the shared LOYALTY policy. Convenience wrapper around `take_shared`.
public fun take_loyalty_policy(
    scenario: &mut sui::test_scenario::Scenario,
): Policy<Balance<LOYALTY>> {
    scenario.take_shared<Policy<Balance<LOYALTY>>>()
}

public fun return_loyalty_policy(p: Policy<Balance<LOYALTY>>) {
    sui::test_scenario::return_shared(p);
}

public fun take_test_usd_policy(
    scenario: &mut sui::test_scenario::Scenario,
): Policy<Balance<TEST_USD>> {
    scenario.take_shared<Policy<Balance<TEST_USD>>>()
}

public fun return_test_usd_policy(p: Policy<Balance<TEST_USD>>) {
    sui::test_scenario::return_shared(p);
}
