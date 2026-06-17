/// E2E tests for the invoice + pay flow.
#[test_only]
module openzeppelin_payments::payment_tests;

use openzeppelin_access::access_control::AccessControl;
use openzeppelin_payments::config;
use openzeppelin_payments::events::{InvoicePaid, InvoiceCanceled};
use openzeppelin_payments::listing;
use openzeppelin_payments::merchant::{
    Self,
    Merchant,
    MERCHANT,
    CashierRole,
    CatalogManagerRole,
    MerchantRole
};
use openzeppelin_payments::receipt;
use openzeppelin_payments::test_setup::{Self, TEST_USD};
use pas::account::{Self, Account};
use pas::e2e;
use pas::policy;
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::clock;
use sui::coin;
use sui::event;
use sui::test_scenario;

const ADMIN: address = @0xA;
const PAYOUT: address = @0xB;
const CUSTOMER: address = @0xCAFE;
const BAD: address = @0xBAD;
const OTHER: address = @0xC0FFEE;

/// Self-minted "stablecoin" used by the wrong-currency abort test.
public struct WRONG_USD has drop {}

#[test]
fun payment_happy_path() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
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
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());

        let _listing_id = merchant.add_listing(&catalog_auth, listing);

        // Merchant POS: issue invoice for 1 × Small Coffee.
        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);
        let invoice_id = merchant.create_invoice(
            &cashier_auth,
            vector[variant_id],
            vector[1],
            b"order-001",
            &test_clock,
            scenario.ctx(),
        );

        // Customer flow: take shared things, build send_funds, approve, pay.
        scenario.next_tx(CUSTOMER);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );
        let payout_account_shared = scenario.take_shared_by_id<Account>(payout_account_id);
        let test_usd_policy = test_setup::take_test_usd_policy(scenario);

        let customer_auth = account::new_auth(scenario.ctx());
        let mut send_req = customer_account_shared.send_balance<TEST_USD>(
            &customer_auth,
            &payout_account_shared,
            500,
            scenario.ctx(),
        );
        test_setup::approve_test_usd(&mut send_req);

        merchant.pay<TEST_USD>(
            invoice_id,
            send_req,
            &test_usd_policy,
            &customer_account_shared,
            &test_clock,
        );

        // `InvoicePaid` was emitted.
        assert!(event::events_by_type<InvoicePaid>().length() == 1, 0);

        // The receipt is stored in the merchant's receipt table, keyed by invoice id.
        let r = merchant.invoice_receipt(invoice_id);
        assert_eq!(receipt::amount(r), 500);
        assert_eq!(receipt::loyalty(r), 50); // 500 * 1/10 = 50, under cap.
        assert_eq!(receipt::payout_address(r), PAYOUT);
        assert_eq!(*receipt::order_ref(r), b"order-001");
        assert_eq!(receipt::timestamp_ms(r), 1_000_000);

        // Cleanup.
        test_setup::return_test_usd_policy(test_usd_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        test_scenario::return_shared(payout_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = merchant::EInvoiceExpired)]
fun pay_after_expiry_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
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
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());

        let _ = merchant.add_listing(&catalog_auth, listing);

        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);
        let invoice_id = merchant.create_invoice(
            &cashier_auth,
            vector[variant_id],
            vector[1],
            b"order-001",
            &test_clock,
            scenario.ctx(),
        );

        // Advance clock past invoice_ttl_ms (600_000).
        test_clock.set_for_testing(2_000_000);

        scenario.next_tx(CUSTOMER);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );
        let payout_account_shared = scenario.take_shared_by_id<Account>(payout_account_id);
        let test_usd_policy = test_setup::take_test_usd_policy(scenario);

        let customer_auth = account::new_auth(scenario.ctx());
        let mut send_req = customer_account_shared.send_balance<TEST_USD>(
            &customer_auth,
            &payout_account_shared,
            500,
            scenario.ctx(),
        );
        test_setup::approve_test_usd(&mut send_req);

        merchant.pay<TEST_USD>(
            invoice_id,
            send_req,
            &test_usd_policy,
            &customer_account_shared,
            &test_clock,
        );

        // Unreachable cleanup.
        test_setup::return_test_usd_policy(test_usd_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        test_scenario::return_shared(payout_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test]
fun cancel_after_expiry_destroys_invoice() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
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
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());

        let _ = merchant.add_listing(&catalog_auth, listing);

        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);
        let invoice_id = merchant.create_invoice(
            &cashier_auth,
            vector[variant_id],
            vector[1],
            b"order-001",
            &test_clock,
            scenario.ctx(),
        );

        // Move past expiry, then cancel permissionlessly.
        test_clock.set_for_testing(2_000_000);
        scenario.next_tx(@0xDEAD);
        merchant.cancel_invoice(invoice_id, &test_clock);

        // `InvoiceCanceled` was emitted.
        assert!(event::events_by_type<InvoiceCanceled>().length() == 1, 0);

        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = merchant::ENotExpired)]
fun cancel_before_expiry_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
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
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());

        let _ = merchant.add_listing(&catalog_auth, listing);

        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);
        let invoice_id = merchant.create_invoice(
            &cashier_auth,
            vector[variant_id],
            vector[1],
            b"order-001",
            &test_clock,
            scenario.ctx(),
        );

        // Try to cancel while the invoice is still live — must abort.
        scenario.next_tx(@0xDEAD);
        merchant.cancel_invoice(invoice_id, &test_clock);

        // Unreachable cleanup.
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = merchant::EListingInactive)]
fun payment_inactive_listing_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
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
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());

        let listing_id = merchant.add_listing(&catalog_auth, listing);
        // Deactivate after adding — cashier should not be able to issue an invoice.
        merchant.set_listing_status(&catalog_auth, listing_id, false);

        let test_clock = clock::create_for_testing(scenario.ctx());

        // Aborts with `merchant::EListingInactive`.
        let _invoice_id = merchant.create_invoice(
            &cashier_auth,
            vector[variant_id],
            vector[1],
            b"order-001",
            &test_clock,
            scenario.ctx(),
        );

        // Unreachable cleanup.
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = merchant::EWrongRecipient)]
fun pay_wrong_recipient_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        let customer_account_id = ns.account_address(CUSTOMER).to_id();
        let customer_account = account::create(ns, CUSTOMER);
        customer_account.deposit_balance(balance::create_for_testing<TEST_USD>(10_000));
        customer_account.share();

        // Two destination accounts — invoice will point at PAYOUT, but the
        // customer's send_funds will target BAD.
        account::create_and_share(ns, PAYOUT);
        let bad_account_id = ns.account_address(BAD).to_id();
        account::create_and_share(ns, BAD);

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
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());

        let _ = merchant.add_listing(&catalog_auth, listing);

        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);
        let invoice_id = merchant.create_invoice(
            &cashier_auth,
            vector[variant_id],
            vector[1],
            b"order-001",
            &test_clock,
            scenario.ctx(),
        );

        scenario.next_tx(CUSTOMER);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );
        let bad_account_shared = scenario.take_shared_by_id<Account>(bad_account_id);
        let test_usd_policy = test_setup::take_test_usd_policy(scenario);

        let customer_auth = account::new_auth(scenario.ctx());
        let mut send_req = customer_account_shared.send_balance<TEST_USD>(
            &customer_auth,
            &bad_account_shared, // recipient = BAD ≠ PAYOUT
            500,
            scenario.ctx(),
        );
        test_setup::approve_test_usd(&mut send_req);

        // Aborts with `merchant::EWrongRecipient`.
        merchant.pay<TEST_USD>(
            invoice_id,
            send_req,
            &test_usd_policy,
            &customer_account_shared,
            &test_clock,
        );

        // Unreachable cleanup.
        test_setup::return_test_usd_policy(test_usd_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        test_scenario::return_shared(bad_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = merchant::EAmountMismatch)]
fun pay_amount_mismatch_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
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
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());

        let _ = merchant.add_listing(&catalog_auth, listing);

        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);
        let invoice_id = merchant.create_invoice(
            &cashier_auth,
            vector[variant_id],
            vector[1],
            b"order-001",
            &test_clock,
            scenario.ctx(),
        );

        scenario.next_tx(CUSTOMER);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );
        let payout_account_shared = scenario.take_shared_by_id<Account>(payout_account_id);
        let test_usd_policy = test_setup::take_test_usd_policy(scenario);

        let customer_auth = account::new_auth(scenario.ctx());
        let mut send_req = customer_account_shared.send_balance<TEST_USD>(
            &customer_auth,
            &payout_account_shared,
            499, // off-by-one against invoice.amount = 500
            scenario.ctx(),
        );
        test_setup::approve_test_usd(&mut send_req);

        // Aborts with `merchant::EAmountMismatch`.
        merchant.pay<TEST_USD>(
            invoice_id,
            send_req,
            &test_usd_policy,
            &customer_account_shared,
            &test_clock,
        );

        // Unreachable cleanup.
        test_setup::return_test_usd_policy(test_usd_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        test_scenario::return_shared(payout_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = merchant::EWrongLoyaltyRecipient)]
fun pay_wrong_loyalty_recipient_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
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

        // Foreign account owned by `OTHER` — will be passed as the loyalty
        // recipient even though the send sender is CUSTOMER.
        let other_account_id = ns.account_address(OTHER).to_id();
        account::create_and_share(ns, OTHER);

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
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());

        let _ = merchant.add_listing(&catalog_auth, listing);

        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);
        let invoice_id = merchant.create_invoice(
            &cashier_auth,
            vector[variant_id],
            vector[1],
            b"order-001",
            &test_clock,
            scenario.ctx(),
        );

        scenario.next_tx(CUSTOMER);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );
        let payout_account_shared = scenario.take_shared_by_id<Account>(payout_account_id);
        let other_account_shared = scenario.take_shared_by_id<Account>(other_account_id);
        let test_usd_policy = test_setup::take_test_usd_policy(scenario);

        let customer_auth = account::new_auth(scenario.ctx());
        let mut send_req = customer_account_shared.send_balance<TEST_USD>(
            &customer_auth,
            &payout_account_shared,
            500,
            scenario.ctx(),
        );
        test_setup::approve_test_usd(&mut send_req);

        // Loyalty recipient account owner is OTHER, not CUSTOMER (the sender) —
        // aborts with `merchant::EWrongLoyaltyRecipient`.
        merchant.pay<TEST_USD>(
            invoice_id,
            send_req,
            &test_usd_policy,
            &other_account_shared,
            &test_clock,
        );

        // Unreachable cleanup.
        test_setup::return_test_usd_policy(test_usd_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        test_scenario::return_shared(payout_account_shared);
        test_scenario::return_shared(other_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test]
fun pay_clamps_loyalty_to_max() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
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
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, MerchantRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());
        let merchant_auth = ac.new_auth<MERCHANT, MerchantRole>(scenario.ctx());

        // Tighten the mint cap to 30. Default mint rate is 1/10, so 500 stable
        // would otherwise mint 50 LOYALTY. The cap clamps it to 30.
        let tight_cfg = config::new(1, 10, 30, 600_000, 600_000);
        merchant.set_config(&merchant_auth, tight_cfg);

        let _ = merchant.add_listing(&catalog_auth, listing);

        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);
        let invoice_id = merchant.create_invoice(
            &cashier_auth,
            vector[variant_id],
            vector[1],
            b"order-001",
            &test_clock,
            scenario.ctx(),
        );

        scenario.next_tx(CUSTOMER);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );
        let payout_account_shared = scenario.take_shared_by_id<Account>(payout_account_id);
        let test_usd_policy = test_setup::take_test_usd_policy(scenario);

        let customer_auth = account::new_auth(scenario.ctx());
        let mut send_req = customer_account_shared.send_balance<TEST_USD>(
            &customer_auth,
            &payout_account_shared,
            500,
            scenario.ctx(),
        );
        test_setup::approve_test_usd(&mut send_req);

        merchant.pay<TEST_USD>(
            invoice_id,
            send_req,
            &test_usd_policy,
            &customer_account_shared,
            &test_clock,
        );

        let r = merchant.invoice_receipt(invoice_id);
        // Uncapped would be 500 / 10 = 50; cap clamps to 30.
        assert_eq!(receipt::amount(r), 500);
        assert_eq!(receipt::loyalty(r), 30);

        test_setup::return_test_usd_policy(test_usd_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        test_scenario::return_shared(payout_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test]
fun payment_receipt_stored_in_merchant() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
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
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());

        let _ = merchant.add_listing(&catalog_auth, listing);

        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);
        let invoice_id = merchant.create_invoice(
            &cashier_auth,
            vector[variant_id],
            vector[1],
            b"order-001",
            &test_clock,
            scenario.ctx(),
        );

        scenario.next_tx(CUSTOMER);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );
        let payout_account_shared = scenario.take_shared_by_id<Account>(payout_account_id);
        let test_usd_policy = test_setup::take_test_usd_policy(scenario);

        let customer_auth = account::new_auth(scenario.ctx());
        let mut send_req = customer_account_shared.send_balance<TEST_USD>(
            &customer_auth,
            &payout_account_shared,
            500,
            scenario.ctx(),
        );
        test_setup::approve_test_usd(&mut send_req);

        merchant.pay<TEST_USD>(
            invoice_id,
            send_req,
            &test_usd_policy,
            &customer_account_shared,
            &test_clock,
        );

        // The receipt is stored in the merchant's receipt table (not owned by
        // the customer). Read it back and verify it records the payment.
        let r = merchant.invoice_receipt(invoice_id);
        assert_eq!(receipt::amount(r), 500);
        assert_eq!(receipt::loyalty(r), 50);
        assert_eq!(receipt::invoice_id(r), invoice_id);

        test_setup::return_test_usd_policy(test_usd_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        test_scenario::return_shared(payout_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = merchant::EWrongPaymentType)]
fun pay_wrong_currency_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        // Merchant is created with TEST_USD as the accepted currency.
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        // Stand up a parallel `WRONG_USD` policy + put `Balance<WRONG_USD>` in
        // the customer's PAS account — as if the customer self-minted their own
        // coin and is trying to pay with it.
        let mut wrong_usd_cap = coin::create_treasury_cap_for_testing<WRONG_USD>(scenario.ctx());
        let (wrong_usd_policy, wrong_usd_policy_cap) = policy::new_for_currency(
            ns,
            &mut wrong_usd_cap,
            false,
        );
        policy::share(wrong_usd_policy);
        destroy(wrong_usd_policy_cap);

        let customer_account_id = ns.account_address(CUSTOMER).to_id();
        let customer_account = account::create(ns, CUSTOMER);
        customer_account.deposit_balance(balance::create_for_testing<WRONG_USD>(10_000));
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
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());

        let _ = merchant.add_listing(&catalog_auth, listing);

        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);
        let invoice_id = merchant.create_invoice(
            &cashier_auth,
            vector[variant_id],
            vector[1],
            b"order-001",
            &test_clock,
            scenario.ctx(),
        );

        scenario.next_tx(CUSTOMER);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );
        let payout_account_shared = scenario.take_shared_by_id<Account>(payout_account_id);
        let wrong_usd_policy_shared = scenario.take_shared<
            policy::Policy<balance::Balance<WRONG_USD>>,
        >();

        let customer_auth = account::new_auth(scenario.ctx());
        let send_req = customer_account_shared.send_balance<WRONG_USD>(
            &customer_auth,
            &payout_account_shared,
            500,
            scenario.ctx(),
        );
        // No approve — `EWrongPaymentType` fires before send_request is read.

        // Aborts with `merchant::EWrongPaymentType` — invoice expects TEST_USD,
        // customer is paying in WRONG_USD.
        merchant.pay<WRONG_USD>(
            invoice_id,
            send_req,
            &wrong_usd_policy_shared,
            &customer_account_shared,
            &test_clock,
        );

        // Unreachable cleanup.
        test_scenario::return_shared(wrong_usd_policy_shared);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        test_scenario::return_shared(payout_account_shared);
        destroy(test_usd_cap);
        destroy(wrong_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = merchant::ENoItems)]
fun new_no_items_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());

        let test_clock = clock::create_for_testing(scenario.ctx());

        // Empty vectors — aborts on `ENoItems`.
        let _invoice_id = merchant.create_invoice(
            &cashier_auth,
            vector[],
            vector[],
            b"order-001",
            &test_clock,
            scenario.ctx(),
        );

        // Unreachable cleanup.
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = merchant::ELengthMismatch)]
fun new_length_mismatch_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
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
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());

        let _ = merchant.add_listing(&catalog_auth, listing);

        let test_clock = clock::create_for_testing(scenario.ctx());

        // 1 variant id, 2 quantities — aborts on `ELengthMismatch`.
        let _invoice_id = merchant.create_invoice(
            &cashier_auth,
            vector[variant_id],
            vector[1, 2],
            b"order-001",
            &test_clock,
            scenario.ctx(),
        );

        // Unreachable cleanup.
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = merchant::EVariantNotFound)]
fun new_variant_not_found_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());

        let test_clock = clock::create_for_testing(scenario.ctx());

        // Variant ID that doesn't exist in the merchant's catalog — aborts via
        // `merchant::active_listing_variant`'s `EVariantNotFound`.
        let phantom = object::id_from_address(@0xDEADBEEF);
        let _invoice_id = merchant.create_invoice(
            &cashier_auth,
            vector[phantom],
            vector[1],
            b"order-001",
            &test_clock,
            scenario.ctx(),
        );

        // Unreachable cleanup.
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test]
fun pay_zero_loyalty_no_mint() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
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
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, MerchantRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());
        let merchant_auth = ac.new_auth<MERCHANT, MerchantRole>(scenario.ctx());

        // mint_numerator = 0 → compute_loyalty(_) = 0 for every payment.
        let zero_cfg = config::new(0, 10, 1_000_000, 600_000, 600_000);
        merchant.set_config(&merchant_auth, zero_cfg);

        let _ = merchant.add_listing(&catalog_auth, listing);

        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);
        let invoice_id = merchant.create_invoice(
            &cashier_auth,
            vector[variant_id],
            vector[1],
            b"order-001",
            &test_clock,
            scenario.ctx(),
        );

        // Capture LOYALTY supply before pay so we can assert no mint occurred.
        let supply_before = coin::total_supply(merchant.loyalty().treasury_cap());

        scenario.next_tx(CUSTOMER);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );
        let payout_account_shared = scenario.take_shared_by_id<Account>(payout_account_id);
        let test_usd_policy = test_setup::take_test_usd_policy(scenario);

        let customer_auth = account::new_auth(scenario.ctx());
        let mut send_req = customer_account_shared.send_balance<TEST_USD>(
            &customer_auth,
            &payout_account_shared,
            500,
            scenario.ctx(),
        );
        test_setup::approve_test_usd(&mut send_req);

        merchant.pay<TEST_USD>(
            invoice_id,
            send_req,
            &test_usd_policy,
            &customer_account_shared,
            &test_clock,
        );

        // Receipt records loyalty = 0 and the supply didn't move.
        let r = merchant.invoice_receipt(invoice_id);
        assert!(receipt::amount(r) == 500, 0);
        assert!(receipt::loyalty(r) == 0, 0);
        let supply_after = coin::total_supply(merchant.loyalty().treasury_cap());
        assert!(supply_before == supply_after, 0);

        test_setup::return_test_usd_policy(test_usd_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        test_scenario::return_shared(payout_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test]
fun pay_with_coin_happy_path() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, mut test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        // Customer PAS account only receives minted LOYALTY — no stablecoin funding,
        // since the customer pays with a plain coin minted below.
        let customer_account_id = ns.account_address(CUSTOMER).to_id();
        let customer_account = account::create(ns, CUSTOMER);
        customer_account.share();

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
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());
        let _ = merchant.add_listing(&catalog_auth, listing);

        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);
        let invoice_id = merchant.create_invoice(
            &cashier_auth,
            vector[variant_id],
            vector[1],
            b"order-001",
            &test_clock,
            scenario.ctx(),
        );

        // Customer settles with a plain, unrestricted coin.
        scenario.next_tx(CUSTOMER);
        let customer_account_shared = scenario.take_shared_by_id<Account>(customer_account_id);
        let payment_coin = coin::mint(&mut test_usd_cap, 500, scenario.ctx());

        merchant.pay_with_coin<TEST_USD>(
            invoice_id,
            payment_coin,
            &customer_account_shared,
            &test_clock,
        );

        assert!(event::events_by_type<InvoicePaid>().length() == 1, 0);

        // Receipt stored, attributed to the loyalty account's owner.
        let r = merchant.invoice_receipt(invoice_id);
        assert_eq!(receipt::amount(r), 500);
        assert_eq!(receipt::loyalty(r), 50);
        assert_eq!(receipt::customer(r), CUSTOMER);
        assert_eq!(receipt::payout_address(r), PAYOUT);

        // The payout address received the funds as a plain owned coin.
        scenario.next_tx(PAYOUT);
        let received = scenario.take_from_address<coin::Coin<TEST_USD>>(PAYOUT);
        assert_eq!(received.value(), 500);

        destroy(received);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = merchant::EAmountMismatch)]
fun pay_with_coin_amount_mismatch_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, mut test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        let customer_account_id = ns.account_address(CUSTOMER).to_id();
        let customer_account = account::create(ns, CUSTOMER);
        customer_account.share();

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
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());
        let _ = merchant.add_listing(&catalog_auth, listing);

        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);
        let invoice_id = merchant.create_invoice(
            &cashier_auth,
            vector[variant_id],
            vector[1],
            b"order-001",
            &test_clock,
            scenario.ctx(),
        );

        scenario.next_tx(CUSTOMER);
        let customer_account_shared = scenario.take_shared_by_id<Account>(customer_account_id);
        // 499 against invoice amount 500 — aborts with `EAmountMismatch`.
        let underpay = coin::mint(&mut test_usd_cap, 499, scenario.ctx());

        merchant.pay_with_coin<TEST_USD>(
            invoice_id,
            underpay,
            &customer_account_shared,
            &test_clock,
        );

        // Unreachable cleanup.
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = merchant::EWrongPaymentType)]
fun pay_with_coin_wrong_currency_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        // Merchant accepts TEST_USD.
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(ns, PAYOUT, scenario.ctx());

        let customer_account_id = ns.account_address(CUSTOMER).to_id();
        let customer_account = account::create(ns, CUSTOMER);
        customer_account.share();

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
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());
        let _ = merchant.add_listing(&catalog_auth, listing);

        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);
        let invoice_id = merchant.create_invoice(
            &cashier_auth,
            vector[variant_id],
            vector[1],
            b"order-001",
            &test_clock,
            scenario.ctx(),
        );

        scenario.next_tx(CUSTOMER);
        let customer_account_shared = scenario.take_shared_by_id<Account>(customer_account_id);
        // Self-minted WRONG_USD against a TEST_USD invoice — aborts with `EWrongPaymentType`.
        let mut wrong_cap = coin::create_treasury_cap_for_testing<WRONG_USD>(scenario.ctx());
        let wrong_coin = coin::mint(&mut wrong_cap, 500, scenario.ctx());

        merchant.pay_with_coin<WRONG_USD>(
            invoice_id,
            wrong_coin,
            &customer_account_shared,
            &test_clock,
        );

        // Unreachable cleanup.
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        destroy(test_usd_cap);
        destroy(wrong_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = merchant::EInvoiceExpired)]
fun pay_with_coin_after_expiry_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, mut test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        let customer_account_id = ns.account_address(CUSTOMER).to_id();
        let customer_account = account::create(ns, CUSTOMER);
        customer_account.share();

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
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());
        let _ = merchant.add_listing(&catalog_auth, listing);

        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);
        let invoice_id = merchant.create_invoice(
            &cashier_auth,
            vector[variant_id],
            vector[1],
            b"order-001",
            &test_clock,
            scenario.ctx(),
        );

        // Advance past invoice_ttl_ms (600_000).
        test_clock.set_for_testing(2_000_000);

        scenario.next_tx(CUSTOMER);
        let customer_account_shared = scenario.take_shared_by_id<Account>(customer_account_id);
        let payment_coin = coin::mint(&mut test_usd_cap, 500, scenario.ctx());

        merchant.pay_with_coin<TEST_USD>(
            invoice_id,
            payment_coin,
            &customer_account_shared,
            &test_clock,
        );

        // Unreachable cleanup.
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}
