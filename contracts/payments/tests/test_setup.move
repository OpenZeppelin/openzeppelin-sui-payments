/// Shared test scaffolding for `openzeppelin_payments` tests.
///
/// Wraps `pas::e2e::test_tx!` to also stand up the `AccessControl<MERCHANT>`
/// registry (via `merchant::init_for_testing`), a `LOYALTY` policy + bundle
/// (via `loyalty::create`), a mock `TEST_USD` stablecoin policy with a
/// permissive approval witness + a `Currency<TEST_USD>` (so `config::new` can
/// read decimals), and a `Merchant` ready to be `take_shared` in the next tx.
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
use sui::coin_registry::{Self, Currency};

// === Test types ===

/// Test-only stablecoin marker. `has key { id: UID }` so it works with
/// `coin_registry::new_currency<T: key>` without needing an OTW — the
/// instance is never constructed, only the type parameter is used.
public struct TEST_USD has key { id: UID }

/// Permissive approval witness for the `TEST_USD` policy. Anyone can produce
/// one — devnet-style.
public struct TestUsdApproval() has drop;

/// Stamp the `TestUsdApproval` witness on a pending `send_funds` request.
public fun approve_test_usd(request: &mut Request<SendFunds<Balance<TEST_USD>>>) {
    request.approve(TestUsdApproval());
}

// === Currency Helper ===

/// Build a real `Currency<TEST_USD>` (0 decimals — keeps test arithmetic in
/// whole "units" rather than fractional human dollars) and its matching
/// `TreasuryCap<TEST_USD>` for tests that call `config::new<TEST_USD>(&currency, ...)`
/// and/or mint test balances.
///
/// Each call creates an internal dummy `TxContext`. `tx_context::dummy()` uses a
/// fixed tx_hash so the first object claimed under it has a deterministic address;
/// a second `new_test_currency` in the same scenario would see the previous claim
/// via shared dynamic-field state and abort with `ECurrencyAlreadyExists`. The
/// `hint` parameter varies the tx_hash so each call gets a fresh derived address —
/// pass any unique `u64` per call site (e.g. `0` for the first call, `1` for the
/// second, etc.).
public fun new_test_currency(hint: u64): (Currency<TEST_USD>, TreasuryCap<TEST_USD>) {
    let ctx =
        &mut tx_context::new(
            @0x0,
            tx_context::dummy_tx_hash_with_hint(hint),
            0,
            0,
            0,
        );
    let mut registry = coin_registry::create_coin_data_registry_for_testing(ctx);
    let (init, treasury_cap) = coin_registry::new_currency<TEST_USD>(
        &mut registry,
        0,
        b"USD".to_string(),
        b"Test USD".to_string(),
        b"Test stablecoin used by openzeppelin_payments tests.".to_string(),
        b"".to_string(),
        ctx,
    );
    let currency = coin_registry::unwrap_for_testing(init);
    destroy(registry);
    (currency, treasury_cap)
}

// === Setup ===

/// Inside a `pas::e2e::test_tx!` body, create the `LOYALTY` + `TEST_USD`
/// policies and a `Merchant` with sane defaults. Shares the Merchant. Returns
/// `(merchant_id, TreasuryCap<TEST_USD>)` — the TreasuryCap is needed by
/// tests to mint balance into customer PAS accounts. The shared
/// `AccessControl<MERCHANT>` registry is set up by `merchant::init_for_testing`
/// (tests should call that themselves before invoking this helper). No
/// operational roles are pre-granted — each test calls
/// `ac.grant_role<MERCHANT, {Merchant,CatalogManager,Cashier}Role>(...)`
/// explicitly for the roles it needs.
public fun setup_merchant(
    namespace: &mut Namespace,
    payout_address: address,
    ctx: &mut TxContext,
): (ID, TreasuryCap<TEST_USD>) {
    // LOYALTY: create the policy + bundle in one call.
    let loyalty_cap = coin::create_treasury_cap_for_testing<LOYALTY>(ctx);
    let loyalty_bundle = loyalty::create(namespace, loyalty_cap);

    // TEST_USD: real `Currency<TEST_USD>` (0 decimals — see `new_test_currency`)
    // + TreasuryCap. Hint `0` here; tests that need a second `Currency<TEST_USD>`
    // must pass a different hint.
    let (test_usd_currency, mut test_usd_cap) = new_test_currency(0);

    // TEST_USD policy with the permissive `TestUsdApproval` for send_funds.
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

    // Merchant config: 0.1 LOY per stablecoin unit (10% of `LOYALTY_FLOAT_SCALING`),
    // cap 1_000_000, 10-minute TTLs.
    let cfg = config::new<TEST_USD>(
        &test_usd_currency,
        payout_address,
        config::loyalty_float_scaling() / 10,
        1_000_000,
        600_000,
        600_000,
    );

    // Currency is no longer needed once `config` has snapshotted decimals.
    destroy(test_usd_currency);

    let m = merchant::create(
        loyalty_bundle,
        cfg,
        b"Test Shop".to_string(),
        std::option::none(),
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
