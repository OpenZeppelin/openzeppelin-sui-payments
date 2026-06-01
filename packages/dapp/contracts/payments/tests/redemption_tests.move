/// E2E tests for the voucher + redeem flow.
#[test_only]
module openzeppelin_payments::redemption_tests;

use openzeppelin_payments::listing;
use openzeppelin_payments::loyalty::LOYALTY;
use openzeppelin_payments::merchant::Merchant;
use openzeppelin_payments::receipt::{Self, Receipt, Redemption};
use openzeppelin_payments::redemption::{Self, Voucher};
use openzeppelin_payments::test_setup;
use pas::account::{Self, Account};
use pas::e2e;
use std::unit_test::destroy;
use sui::balance;
use sui::clock;
use sui::test_scenario;

const ADMIN: address = @0xA;
const PAYOUT: address = @0xB;
const CUSTOMER: address = @0xCAFE;

#[test]
fun redemption_happy_path() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        let (merchant_id, cap, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        // Customer PAS account (unfunded for now; we'll mint via the merchant
        // treasury cap below so the supply counter matches the circulating
        // balance — `balance::decrease_supply` asserts on this in `redeem`).
        let customer_account_id = ns.account_address(CUSTOMER).to_id();
        account::create_and_share(ns, CUSTOMER);

        // Catalog: one listing with a variant priced 50 (LOYALTY units in this flow).
        let mut listing = listing::new(b"Free Drink".to_string(), scenario.ctx());
        let variant = listing::new_variant(
            b"Small".to_string(),
            50,
            std::option::none(),
            scenario.ctx(),
        );
        let variant_id = listing.add_variant(variant);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );
        let _ = merchant.add_listing(&cap, listing);

        // Mint LOYALTY for the customer via the merchant-held TreasuryCap so
        // supply == circulation. (For tests only — production flow has the
        // customer earn LOYALTY through `invoice::pay`.)
        let loyalty_bal = merchant.loyalty_mut().treasury_cap_mut().mint_balance(100);
        customer_account_shared.deposit_balance(loyalty_bal);

        // Customer: build unlock request, then voucher.
        scenario.next_tx(CUSTOMER);
        let loyalty_policy = test_setup::take_loyalty_policy(scenario);

        let auth = account::new_auth(scenario.ctx());
        let unlock_req = customer_account_shared.unlock_balance<LOYALTY>(
            &auth,
            50,
            scenario.ctx(),
        );

        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);

        let voucher = redemption::new(
            &merchant,
            unlock_req,
            &loyalty_policy,
            vector[variant_id],
            vector[1],
            &test_clock,
            scenario.ctx(),
        );
        let voucher_id = object::id(&voucher);
        redemption::share(voucher);

        // Merchant redeems.
        scenario.next_tx(ADMIN);
        let v_shared = scenario.take_shared_by_id<Voucher>(voucher_id);
        redemption::redeem(v_shared, &cap, &mut merchant, &test_clock, scenario.ctx());

        // Customer receives the RedemptionReceipt.
        scenario.next_tx(CUSTOMER);
        let r = scenario.take_from_sender<Receipt<Redemption>>();
        assert!(receipt::amount(&r) == 50, 0);
        assert!(receipt::timestamp_ms(&r) == 1_000_000, 0);

        destroy(r);
        test_setup::return_loyalty_policy(loyalty_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(customer_account_shared);
        destroy(cap);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = redemption::EVoucherExpired)]
fun redeem_after_expiry_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        let (merchant_id, cap, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        let customer_account_id = ns.account_address(CUSTOMER).to_id();
        let customer_account = account::create(ns, CUSTOMER);
        customer_account.deposit_balance(balance::create_for_testing<LOYALTY>(100));
        customer_account.share();

        let mut listing = listing::new(b"Free Drink".to_string(), scenario.ctx());
        let variant = listing::new_variant(
            b"S".to_string(),
            50,
            std::option::none(),
            scenario.ctx(),
        );
        let variant_id = listing.add_variant(variant);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let _ = merchant.add_listing(&cap, listing);

        scenario.next_tx(CUSTOMER);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );
        let loyalty_policy = test_setup::take_loyalty_policy(scenario);

        let auth = account::new_auth(scenario.ctx());
        let unlock_req = customer_account_shared.unlock_balance<LOYALTY>(
            &auth,
            50,
            scenario.ctx(),
        );

        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);

        let voucher = redemption::new(
            &merchant,
            unlock_req,
            &loyalty_policy,
            vector[variant_id],
            vector[1],
            &test_clock,
            scenario.ctx(),
        );
        let voucher_id = object::id(&voucher);
        redemption::share(voucher);

        // Advance past voucher_ttl_ms (600_000).
        test_clock.set_for_testing(2_000_000);

        scenario.next_tx(ADMIN);
        let v_shared = scenario.take_shared_by_id<Voucher>(voucher_id);
        redemption::redeem(v_shared, &cap, &mut merchant, &test_clock, scenario.ctx());

        // Unreachable cleanup.
        test_setup::return_loyalty_policy(loyalty_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(customer_account_shared);
        destroy(cap);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test]
fun cancel_voucher_returns_funds() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        let (merchant_id, cap, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        let customer_account_id = ns.account_address(CUSTOMER).to_id();
        let customer_account = account::create(ns, CUSTOMER);
        customer_account.deposit_balance(balance::create_for_testing<LOYALTY>(100));
        customer_account.share();

        let mut listing = listing::new(b"Drink".to_string(), scenario.ctx());
        let variant = listing::new_variant(
            b"S".to_string(),
            50,
            std::option::none(),
            scenario.ctx(),
        );
        let variant_id = listing.add_variant(variant);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let _ = merchant.add_listing(&cap, listing);

        scenario.next_tx(CUSTOMER);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );
        let loyalty_policy = test_setup::take_loyalty_policy(scenario);

        let auth = account::new_auth(scenario.ctx());
        let unlock_req = customer_account_shared.unlock_balance<LOYALTY>(
            &auth,
            50,
            scenario.ctx(),
        );

        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);
        let voucher = redemption::new(
            &merchant,
            unlock_req,
            &loyalty_policy,
            vector[variant_id],
            vector[1],
            &test_clock,
            scenario.ctx(),
        );
        let voucher_id = object::id(&voucher);
        redemption::share(voucher);

        // Past expiry, permissionless cancel by another address.
        test_clock.set_for_testing(2_000_000);
        scenario.next_tx(@0xDEAD);
        let v_shared = scenario.take_shared_by_id<Voucher>(voucher_id);
        redemption::cancel(v_shared, &customer_account_shared, &test_clock);

        test_setup::return_loyalty_policy(loyalty_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(customer_account_shared);
        destroy(cap);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}
