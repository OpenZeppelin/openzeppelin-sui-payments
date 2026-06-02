/// Shared test scaffolding for `openzeppelin_payments` tests.
///
/// Wraps `pas::e2e::test_tx!` to also stand up the `AccessControl<MERCHANT>`
/// registry (via `merchant::init_for_testing`), a `LOYALTY` policy + bundle
/// (via `loyalty::create`), a mock `TEST_USD` stablecoin policy with a
/// permissive approval witness, and a `Merchant` ready to be `take_shared` in
/// the next tx.
#[test_only]
module openzeppelin_payments::test_setup;

use openzeppelin_payments::config;
use openzeppelin_payments::loyalty::{Self, LOYALTY};
use openzeppelin_payments::merchant;
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
public fun approve_test_usd(request: &mut Request<SendFunds<Balance<TEST_USD>>>) {
    request.approve(TestUsdApproval());
}

// === Setup ===

/// Inside a `pas::e2e::test_tx!` body, create the `LOYALTY` + `TEST_USD`
/// policies and a `Merchant` with sane defaults. Shares the Merchant. Returns
/// `(merchant_id, TreasuryCap<TEST_USD>)` — the TreasuryCap is needed by
/// tests to mint balance into customer PAS accounts. The shared
/// `AccessControl<MERCHANT>` registry (with `OperatorRole` granted to the
/// tx sender) is set up by `merchant::init_for_testing`; tests should call
/// that themselves before invoking this helper so the registry exists in the
/// scenario.
public fun setup_merchant(
    namespace: &mut Namespace,
    payout_address: address,
    ctx: &mut TxContext,
): (ID, TreasuryCap<TEST_USD>) {
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

    let m = merchant::create(
        loyalty_bundle,
        cfg,
        b"Test Shop".to_string(),
        std::option::none(),
        payout_address,
        ctx,
    );
    let merchant_id = object::id(&m);
    merchant::share(m);

    (merchant_id, test_usd_cap)
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
