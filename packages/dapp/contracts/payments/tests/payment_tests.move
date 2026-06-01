/// E2E tests for the invoice + pay flow.
#[test_only]
module openzeppelin_payments::payment_tests;

use openzeppelin_payments::invoice::{Self, Invoice};
use openzeppelin_payments::listing;
use openzeppelin_payments::merchant::Merchant;
use openzeppelin_payments::receipt::{Self, Receipt, Payment};
use openzeppelin_payments::test_setup::{Self, TEST_USD};
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
fun payment_happy_path() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        let (merchant_id, cap, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        // Customer PAS account: create, fund with TEST_USD, share.
        let customer_account_id = ns.account_address(CUSTOMER).to_id();
        let customer_account = account::create(ns, CUSTOMER);
        customer_account.deposit_balance(balance::create_for_testing<TEST_USD>(10_000));
        customer_account.share();

        // Merchant's payout PAS account (resolve target for send_funds).
        let payout_account_id = ns.account_address(PAYOUT).to_id();
        account::create_and_share(ns, PAYOUT);

        // Catalog: one listing with one variant priced at 500.
        let mut listing = listing::new(b"Coffee".to_string(), scenario.ctx());
        let variant = listing::new_variant(
            b"Small".to_string(),
            500,
            std::option::none(),
            scenario.ctx(),
        );
        let variant_id = listing.add_variant(variant);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let _listing_id = merchant.add_listing(&cap, listing);

        // Merchant POS: issue invoice for 1 × Small Coffee.
        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);
        let inv = invoice::new(
            &merchant,
            &cap,
            vector[variant_id],
            vector[1],
            b"order-001",
            &test_clock,
            scenario.ctx(),
        );
        let invoice_id = object::id(&inv);
        invoice::share(inv);

        // Customer flow: take shared things, build send_funds, approve, pay.
        scenario.next_tx(CUSTOMER);
        let inv_shared = scenario.take_shared_by_id<Invoice>(invoice_id);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );
        let payout_account_shared = scenario.take_shared_by_id<Account>(payout_account_id);
        let test_usd_policy = test_setup::take_test_usd_policy(scenario);

        let auth = account::new_auth(scenario.ctx());
        let mut send_req = customer_account_shared.send_balance<TEST_USD>(
            &auth,
            &payout_account_shared,
            500,
            scenario.ctx(),
        );
        test_setup::approve_test_usd(&mut send_req);

        invoice::pay<TEST_USD>(
            inv_shared,
            &mut merchant,
            send_req,
            &test_usd_policy,
            &customer_account_shared,
            &test_clock,
            scenario.ctx(),
        );

        // Verify the soulbound receipt landed in the customer's owned objects.
        scenario.next_tx(CUSTOMER);
        let r = scenario.take_from_sender<Receipt<Payment>>();
        assert!(receipt::amount(&r) == 500, 0);
        assert!(receipt::loyalty(&r) == 50, 0); // 500 * 1/10 = 50, under cap.
        assert!(receipt::payout_address(&r) == PAYOUT, 0);
        assert!(receipt::order_ref(&r) == b"order-001", 0);
        assert!(receipt::timestamp_ms(&r) == 1_000_000, 0);

        // Cleanup.
        destroy(r);
        test_setup::return_test_usd_policy(test_usd_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(customer_account_shared);
        test_scenario::return_shared(payout_account_shared);
        destroy(cap);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = invoice::EInvoiceExpired)]
fun pay_after_expiry_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        let (merchant_id, cap, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        let customer_account_id = ns.account_address(CUSTOMER).to_id();
        let customer_account = account::create(ns, CUSTOMER);
        customer_account.deposit_balance(balance::create_for_testing<TEST_USD>(10_000));
        customer_account.share();

        let payout_account_id = ns.account_address(PAYOUT).to_id();
        account::create_and_share(ns, PAYOUT);

        let mut listing = listing::new(b"Coffee".to_string(), scenario.ctx());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::none(),
            scenario.ctx(),
        );
        let variant_id = listing.add_variant(variant);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let _ = merchant.add_listing(&cap, listing);

        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);
        let inv = invoice::new(
            &merchant,
            &cap,
            vector[variant_id],
            vector[1],
            b"order-001",
            &test_clock,
            scenario.ctx(),
        );
        let invoice_id = object::id(&inv);
        invoice::share(inv);

        // Advance clock past invoice_ttl_ms (600_000).
        test_clock.set_for_testing(2_000_000);

        scenario.next_tx(CUSTOMER);
        let inv_shared = scenario.take_shared_by_id<Invoice>(invoice_id);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );
        let payout_account_shared = scenario.take_shared_by_id<Account>(payout_account_id);
        let test_usd_policy = test_setup::take_test_usd_policy(scenario);

        let auth = account::new_auth(scenario.ctx());
        let mut send_req = customer_account_shared.send_balance<TEST_USD>(
            &auth,
            &payout_account_shared,
            500,
            scenario.ctx(),
        );
        test_setup::approve_test_usd(&mut send_req);

        invoice::pay<TEST_USD>(
            inv_shared,
            &mut merchant,
            send_req,
            &test_usd_policy,
            &customer_account_shared,
            &test_clock,
            scenario.ctx(),
        );

        // Unreachable cleanup (kept so the compiler can typecheck the block).
        test_setup::return_test_usd_policy(test_usd_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(customer_account_shared);
        test_scenario::return_shared(payout_account_shared);
        destroy(cap);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test]
fun cancel_after_expiry_destroys_invoice() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        let (merchant_id, cap, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        let mut listing = listing::new(b"Coffee".to_string(), scenario.ctx());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::none(),
            scenario.ctx(),
        );
        let variant_id = listing.add_variant(variant);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let _ = merchant.add_listing(&cap, listing);

        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);
        let inv = invoice::new(
            &merchant,
            &cap,
            vector[variant_id],
            vector[1],
            b"order-001",
            &test_clock,
            scenario.ctx(),
        );
        let invoice_id = object::id(&inv);
        invoice::share(inv);

        // Move past expiry, then cancel permissionlessly.
        test_clock.set_for_testing(2_000_000);
        scenario.next_tx(@0xDEAD);
        let inv_shared = scenario.take_shared_by_id<Invoice>(invoice_id);
        invoice::cancel(inv_shared, &test_clock);

        test_scenario::return_shared(merchant);
        destroy(cap);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}
