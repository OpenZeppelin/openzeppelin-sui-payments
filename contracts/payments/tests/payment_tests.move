/// E2E tests for the invoice + pay flow.
#[test_only]
module openzeppelin_payments::payment_tests;

use openzeppelin_access::access_control::AccessControl;
use openzeppelin_payments::config;
use openzeppelin_payments::events;
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
use openzeppelin_payments::test_helpers::assert_emitted;
use openzeppelin_payments::test_setup::{Self, TEST_USD};
use pas::account::{Self, Account};
use pas::e2e;
use pas::policy;
use std::type_name;
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::clock;
use sui::coin;
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
        let mut listing = listing::new(b"Coffee".to_string());
        let variant = listing::new_variant(
            b"Small".to_string(),
            500,
            std::option::none(),
        );
        let variant_id = object::id_from_address(scenario.ctx().fresh_object_address());
        listing.add_variant(variant, variant_id);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());

        let _listing_id = merchant.add_listing(&catalog_auth, listing, scenario.ctx());

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

        // The accepted currency is pinned onto the invoice at issuance.
        assert_eq!(
            merchant.invoice(invoice_id).payment_type(),
            type_name::with_defining_ids<TEST_USD>(),
        );

        // `InvoiceCreated` was emitted with the issuance ID (asserted in the same tx
        // as `create_invoice`, before `next_tx`).
        assert_emitted!(events::invoice_created(invoice_id));

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

        // `InvoicePaid` was emitted with the expected payload.
        assert_emitted!(
            events::invoice_paid(
                invoice_id,
                b"order-001",
                CUSTOMER,
                PAYOUT,
                type_name::with_defining_ids<TEST_USD>(),
                500,
                50,
                1_000_000,
                false, // PAS `pay` path
            ),
        );

        // The receipt is stored in the merchant's receipt table, keyed by invoice id.
        let r = merchant.invoice_receipt(invoice_id);
        assert_eq!(receipt::amount(r), 500);
        assert_eq!(receipt::loyalty(r), 50); // 500 * 1/10 = 50, under cap.
        assert_eq!(receipt::payout_address(r), PAYOUT);
        assert_eq!(receipt::payment_type(r), type_name::with_defining_ids<TEST_USD>());
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

        let mut listing = listing::new(b"Coffee".to_string());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::none(),
        );
        let variant_id = object::id_from_address(scenario.ctx().fresh_object_address());
        listing.add_variant(variant, variant_id);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());

        let _ = merchant.add_listing(&catalog_auth, listing, scenario.ctx());

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

        let mut listing = listing::new(b"Coffee".to_string());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::none(),
        );
        let variant_id = object::id_from_address(scenario.ctx().fresh_object_address());
        listing.add_variant(variant, variant_id);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());

        let _ = merchant.add_listing(&catalog_auth, listing, scenario.ctx());

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

        // `InvoiceCanceled` was emitted with the expected payload.
        assert_emitted!(
            events::invoice_canceled(
                invoice_id,
                PAYOUT,
                type_name::with_defining_ids<TEST_USD>(),
                500,
                b"order-001",
            ),
        );

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

        let mut listing = listing::new(b"Coffee".to_string());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::none(),
        );
        let variant_id = object::id_from_address(scenario.ctx().fresh_object_address());
        listing.add_variant(variant, variant_id);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());

        let _ = merchant.add_listing(&catalog_auth, listing, scenario.ctx());

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

        let mut listing = listing::new(b"Coffee".to_string());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::none(),
        );
        let variant_id = object::id_from_address(scenario.ctx().fresh_object_address());
        listing.add_variant(variant, variant_id);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());

        let listing_id = merchant.add_listing(&catalog_auth, listing, scenario.ctx());
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

        let mut listing = listing::new(b"Coffee".to_string());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::none(),
        );
        let variant_id = object::id_from_address(scenario.ctx().fresh_object_address());
        listing.add_variant(variant, variant_id);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());

        let _ = merchant.add_listing(&catalog_auth, listing, scenario.ctx());

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

        let mut listing = listing::new(b"Coffee".to_string());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::none(),
        );
        let variant_id = object::id_from_address(scenario.ctx().fresh_object_address());
        listing.add_variant(variant, variant_id);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());

        let _ = merchant.add_listing(&catalog_auth, listing, scenario.ctx());

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

        let mut listing = listing::new(b"Coffee".to_string());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::none(),
        );
        let variant_id = object::id_from_address(scenario.ctx().fresh_object_address());
        listing.add_variant(variant, variant_id);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());

        let _ = merchant.add_listing(&catalog_auth, listing, scenario.ctx());

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

        let mut listing = listing::new(b"Coffee".to_string());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::none(),
        );
        let variant_id = object::id_from_address(scenario.ctx().fresh_object_address());
        listing.add_variant(variant, variant_id);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, MerchantRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());
        let merchant_auth = ac.new_auth<MERCHANT, MerchantRole>(scenario.ctx());

        // Tighten the mint cap to 30. Default rate is 0.1 LOY per unit, so 500
        // stable would otherwise mint 50 LOYALTY. The cap clamps it to 30.
        let (cap_currency, cap_treasury) = test_setup::new_test_currency(1);
        let tight_cfg = config::new<TEST_USD>(
            &cap_currency,
            PAYOUT,
            config::loyalty_float_scaling() / 10,
            30,
            600_000,
            600_000,
        );
        merchant.update_config(&merchant_auth, tight_cfg);
        destroy(cap_currency);
        destroy(cap_treasury);

        let _ = merchant.add_listing(&catalog_auth, listing, scenario.ctx());

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

        let mut listing = listing::new(b"Coffee".to_string());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::none(),
        );
        let variant_id = object::id_from_address(scenario.ctx().fresh_object_address());
        listing.add_variant(variant, variant_id);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());

        let _ = merchant.add_listing(&catalog_auth, listing, scenario.ctx());

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

        let mut listing = listing::new(b"Coffee".to_string());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::none(),
        );
        let variant_id = object::id_from_address(scenario.ctx().fresh_object_address());
        listing.add_variant(variant, variant_id);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());

        let _ = merchant.add_listing(&catalog_auth, listing, scenario.ctx());

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

        let mut listing = listing::new(b"Coffee".to_string());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::none(),
        );
        let variant_id = object::id_from_address(scenario.ctx().fresh_object_address());
        listing.add_variant(variant, variant_id);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());

        let _ = merchant.add_listing(&catalog_auth, listing, scenario.ctx());

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

        let mut listing = listing::new(b"Coffee".to_string());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::none(),
        );
        let variant_id = object::id_from_address(scenario.ctx().fresh_object_address());
        listing.add_variant(variant, variant_id);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, MerchantRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());
        let merchant_auth = ac.new_auth<MERCHANT, MerchantRole>(scenario.ctx());

        // loyalty_coefficient = 0 → compute_loyalty(_) = 0 for every payment.
        let (zero_currency, zero_treasury) = test_setup::new_test_currency(1);
        let zero_cfg = config::new<TEST_USD>(
            &zero_currency,
            PAYOUT,
            0,
            1_000_000,
            600_000,
            600_000,
        );
        merchant.update_config(&merchant_auth, zero_cfg);
        destroy(zero_currency);
        destroy(zero_treasury);

        let _ = merchant.add_listing(&catalog_auth, listing, scenario.ctx());

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
        let supply_before = merchant.loyalty_supply();

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
        let supply_after = merchant.loyalty_supply();
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

        let mut listing = listing::new(b"Coffee".to_string());
        let variant = listing::new_variant(
            b"Small".to_string(),
            500,
            std::option::none(),
        );
        let variant_id = object::id_from_address(scenario.ctx().fresh_object_address());
        listing.add_variant(variant, variant_id);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());
        let _ = merchant.add_listing(&catalog_auth, listing, scenario.ctx());

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

        assert_emitted!(
            events::invoice_paid(
                invoice_id,
                b"order-001",
                CUSTOMER,
                PAYOUT,
                type_name::with_defining_ids<TEST_USD>(),
                500,
                50,
                1_000_000,
                true, // open-loop `pay_with_coin` path
            ),
        );

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

// Pins branch: pay_with_coin<C> / given zero coefficient / it mints 0 LOY.
// Open-loop counterpart of `pay_zero_loyalty_no_mint` — locks symmetry between
// the two settlement codepaths so a future change to one is forced to consider
// the other.
#[test]
fun pay_with_coin_zero_loyalty_no_mint() {
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

        let mut listing = listing::new(b"Coffee".to_string());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::none(),
        );
        let variant_id = object::id_from_address(scenario.ctx().fresh_object_address());
        listing.add_variant(variant, variant_id);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, MerchantRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());
        let merchant_auth = ac.new_auth<MERCHANT, MerchantRole>(scenario.ctx());

        // loyalty_coefficient = 0 → compute_loyalty(_) = 0 regardless of amount.
        let (zero_currency, zero_treasury) = test_setup::new_test_currency(1);
        let zero_cfg = config::new<TEST_USD>(
            &zero_currency,
            PAYOUT,
            0,
            1_000_000,
            600_000,
            600_000,
        );
        merchant.update_config(&merchant_auth, zero_cfg);
        destroy(zero_currency);
        destroy(zero_treasury);

        let _ = merchant.add_listing(&catalog_auth, listing, scenario.ctx());

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

        let supply_before = merchant.loyalty_supply();

        scenario.next_tx(CUSTOMER);
        let customer_account_shared = scenario.take_shared_by_id<Account>(customer_account_id);
        let payment_coin = coin::mint(&mut test_usd_cap, 500, scenario.ctx());

        merchant.pay_with_coin<TEST_USD>(
            invoice_id,
            payment_coin,
            &customer_account_shared,
            &test_clock,
        );

        let r = merchant.invoice_receipt(invoice_id);
        assert_eq!(receipt::amount(r), 500);
        assert_eq!(receipt::loyalty(r), 0);
        assert_eq!(merchant.loyalty_supply(), supply_before);

        // The payout still received the stablecoin (loyalty side is independent).
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

// Pins branch: pay_with_coin<C> / given amount * coefficient > max / it clamps.
// Open-loop counterpart of `pay_clamps_loyalty_to_max`.
#[test]
fun pay_with_coin_clamps_loyalty_to_max() {
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

        let mut listing = listing::new(b"Coffee".to_string());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::none(),
        );
        let variant_id = object::id_from_address(scenario.ctx().fresh_object_address());
        listing.add_variant(variant, variant_id);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, MerchantRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());
        let merchant_auth = ac.new_auth<MERCHANT, MerchantRole>(scenario.ctx());

        // Tighten the mint cap to 30. Default rate is 0.1 LOY per unit, so 500
        // stable would otherwise mint 50 LOYALTY. The cap clamps it to 30.
        let (cap_currency, cap_treasury) = test_setup::new_test_currency(1);
        let tight_cfg = config::new<TEST_USD>(
            &cap_currency,
            PAYOUT,
            config::loyalty_float_scaling() / 10,
            30,
            600_000,
            600_000,
        );
        merchant.update_config(&merchant_auth, tight_cfg);
        destroy(cap_currency);
        destroy(cap_treasury);

        let _ = merchant.add_listing(&catalog_auth, listing, scenario.ctx());

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
        // Snapshotted loyalty already reflects the clamp.
        assert_eq!(merchant.invoice(invoice_id).loyalty(), 30);

        scenario.next_tx(CUSTOMER);
        let customer_account_shared = scenario.take_shared_by_id<Account>(customer_account_id);
        let payment_coin = coin::mint(&mut test_usd_cap, 500, scenario.ctx());

        merchant.pay_with_coin<TEST_USD>(
            invoice_id,
            payment_coin,
            &customer_account_shared,
            &test_clock,
        );

        // Receipt confirms only the cap was minted.
        let r = merchant.invoice_receipt(invoice_id);
        assert_eq!(receipt::loyalty(r), 30);

        scenario.next_tx(PAYOUT);
        let received = scenario.take_from_address<coin::Coin<TEST_USD>>(PAYOUT);
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

        let mut listing = listing::new(b"Coffee".to_string());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::none(),
        );
        let variant_id = object::id_from_address(scenario.ctx().fresh_object_address());
        listing.add_variant(variant, variant_id);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());
        let _ = merchant.add_listing(&catalog_auth, listing, scenario.ctx());

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

        let mut listing = listing::new(b"Coffee".to_string());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::none(),
        );
        let variant_id = object::id_from_address(scenario.ctx().fresh_object_address());
        listing.add_variant(variant, variant_id);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());
        let _ = merchant.add_listing(&catalog_auth, listing, scenario.ctx());

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

        let mut listing = listing::new(b"Coffee".to_string());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::none(),
        );
        let variant_id = object::id_from_address(scenario.ctx().fresh_object_address());
        listing.add_variant(variant, variant_id);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());
        let _ = merchant.add_listing(&catalog_auth, listing, scenario.ctx());

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

#[test, expected_failure(abort_code = merchant::EReceiptNotFound)]
fun prune_invoice_receipts_removes_receipt() {
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

        let mut listing = listing::new(b"Coffee".to_string());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::none(),
        );
        let variant_id = object::id_from_address(scenario.ctx().fresh_object_address());
        listing.add_variant(variant, variant_id);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, MerchantRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());
        let merchant_auth = ac.new_auth<MERCHANT, MerchantRole>(scenario.ctx());
        let _ = merchant.add_listing(&catalog_auth, listing, scenario.ctx());

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
        let payment_coin = coin::mint(&mut test_usd_cap, 500, scenario.ctx());
        merchant.pay_with_coin<TEST_USD>(
            invoice_id,
            payment_coin,
            &customer_account_shared,
            &test_clock,
        );

        // Prune the stored receipt; reading it afterwards aborts `EReceiptNotFound`.
        merchant.prune_invoice_receipts(&merchant_auth, vector[invoice_id]);
        let _ = merchant.invoice_receipt(invoice_id);

        // Unreachable cleanup.
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = merchant::EReceiptNotFound)]
fun prune_invoice_receipts_unknown_id_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(ns, PAYOUT, scenario.ctx());

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, MerchantRole>(ADMIN, scenario.ctx());
        let merchant_auth = ac.new_auth<MERCHANT, MerchantRole>(scenario.ctx());

        // No receipt with this ID — aborts `EReceiptNotFound`.
        let phantom = object::id_from_address(@0xDEADBEEF);
        merchant.prune_invoice_receipts(&merchant_auth, vector[phantom]);

        // Unreachable cleanup.
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        destroy(test_usd_cap);
    });
}

#[test, expected_failure(abort_code = merchant::EZeroQuantity)]
fun new_zero_quantity_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(ns, PAYOUT, scenario.ctx());

        let mut listing = listing::new(b"Coffee".to_string());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::none(),
        );
        let variant_id = object::id_from_address(scenario.ctx().fresh_object_address());
        listing.add_variant(variant, variant_id);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());
        let _ = merchant.add_listing(&catalog_auth, listing, scenario.ctx());

        let test_clock = clock::create_for_testing(scenario.ctx());

        // Quantity 0 — aborts on `EZeroQuantity`.
        let _ = merchant.create_invoice(
            &cashier_auth,
            vector[variant_id],
            vector[0],
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

#[test, expected_failure(abort_code = merchant::EOrderRefTooLong)]
fun create_invoice_order_ref_too_long_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(ns, PAYOUT, scenario.ctx());

        let mut listing = listing::new(b"Coffee".to_string());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::none(),
        );
        let variant_id = object::id_from_address(scenario.ctx().fresh_object_address());
        listing.add_variant(variant, variant_id);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());
        let _ = merchant.add_listing(&catalog_auth, listing, scenario.ctx());

        let test_clock = clock::create_for_testing(scenario.ctx());

        // Cap is 256 bytes; build a 257-byte `order_ref` to trip the bound.
        let mut order_ref = vector[];
        let mut i: u64 = 0;
        while (i < 257) {
            order_ref.push_back(b"x"[0]);
            i = i + 1;
        };

        let _ = merchant.create_invoice(
            &cashier_auth,
            vector[variant_id],
            vector[1],
            order_ref,
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

#[test, expected_failure(abort_code = merchant::EItemsTooMany)]
fun create_invoice_too_many_items_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(ns, PAYOUT, scenario.ctx());

        let mut listing = listing::new(b"Coffee".to_string());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::none(),
        );
        let variant_id = object::id_from_address(scenario.ctx().fresh_object_address());
        listing.add_variant(variant, variant_id);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());
        let _ = merchant.add_listing(&catalog_auth, listing, scenario.ctx());

        let test_clock = clock::create_for_testing(scenario.ctx());

        // Cap is 256 items; build 257-entry parallel vectors to trip the bound.
        let mut ids = vector[];
        let mut qtys = vector[];
        let mut i: u64 = 0;
        while (i < 257) {
            ids.push_back(variant_id);
            qtys.push_back(1);
            i = i + 1;
        };

        let _ = merchant.create_invoice(
            &cashier_auth,
            ids,
            qtys,
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

// Pins branch: create_invoice / given items.length() == MAX_INVOICE_ITEMS / it returns ok.
// Paired with `create_invoice_too_many_items_aborts` — confirms the cap is `<=` not `<`.
#[test]
fun create_invoice_at_items_cap_succeeds() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(ns, PAYOUT, scenario.ctx());

        let mut listing = listing::new(b"Coffee".to_string());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::none(),
        );
        let variant_id = object::id_from_address(scenario.ctx().fresh_object_address());
        listing.add_variant(variant, variant_id);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());
        let _ = merchant.add_listing(&catalog_auth, listing, scenario.ctx());

        let test_clock = clock::create_for_testing(scenario.ctx());

        // Exactly 256 items — boundary value (should pass).
        let mut ids = vector[];
        let mut qtys = vector[];
        let mut i: u64 = 0;
        while (i < 256) {
            ids.push_back(variant_id);
            qtys.push_back(1);
            i = i + 1;
        };

        let invoice_id = merchant.create_invoice(
            &cashier_auth,
            ids,
            qtys,
            b"order-001",
            &test_clock,
            scenario.ctx(),
        );
        assert_eq!(merchant.invoice(invoice_id).items().length(), 256);

        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

// Pins branch: create_invoice / given order_ref.length() == MAX_ORDER_REF_LEN / it returns ok.
// Paired with `create_invoice_order_ref_too_long_aborts` — confirms `<=` direction.
#[test]
fun create_invoice_at_order_ref_cap_succeeds() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(ns, PAYOUT, scenario.ctx());

        let mut listing = listing::new(b"Coffee".to_string());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::none(),
        );
        let variant_id = object::id_from_address(scenario.ctx().fresh_object_address());
        listing.add_variant(variant, variant_id);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());
        let _ = merchant.add_listing(&catalog_auth, listing, scenario.ctx());

        let test_clock = clock::create_for_testing(scenario.ctx());

        // Exactly 256-byte order_ref — boundary value.
        let mut order_ref = vector[];
        let mut i: u64 = 0;
        while (i < 256) {
            order_ref.push_back(b"x"[0]);
            i = i + 1;
        };

        let invoice_id = merchant.create_invoice(
            &cashier_auth,
            vector[variant_id],
            vector[1],
            order_ref,
            &test_clock,
            scenario.ctx(),
        );
        assert_eq!(merchant.invoice(invoice_id).order_ref().length(), 256);

        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

// Pins branch: merchant::invoice_receipt / given receipt missing / it aborts EReceiptNotFound.
// Pairs with `prune_invoice_receipts_unknown_id_aborts` — locks the view-fn contract
// independently of the prune path.
#[test, expected_failure(abort_code = merchant::EReceiptNotFound)]
fun invoice_receipt_unknown_id_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(ns, PAYOUT, scenario.ctx());

        scenario.next_tx(ADMIN);
        let merchant = scenario.take_shared_by_id<Merchant>(merchant_id);

        let phantom = object::id_from_address(@0xDEADBEEF);
        let _r = merchant.invoice_receipt(phantom);

        // Unreachable.
        test_scenario::return_shared(merchant);
        destroy(test_usd_cap);
    });
}

// Pins branch: receipt::compute_total / given items overflow u64 / it aborts EAmountOverflow.
// Triggered via `create_invoice` with a variant priced at u64::MAX and quantity = 2,
// whose product overflows the `checked_mul` inside compute_total.
#[test, expected_failure(abort_code = receipt::EAmountOverflow)]
fun compute_total_overflow_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(ns, PAYOUT, scenario.ctx());

        let mut listing = listing::new(b"Coffee".to_string());
        let variant = listing::new_variant(
            b"S".to_string(),
            18_446_744_073_709_551_615, // u64::MAX
            std::option::none(),
        );
        let variant_id = object::id_from_address(scenario.ctx().fresh_object_address());
        listing.add_variant(variant, variant_id);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());
        let _ = merchant.add_listing(&catalog_auth, listing, scenario.ctx());

        let test_clock = clock::create_for_testing(scenario.ctx());
        // 2 × u64::MAX overflows u64 in the checked_mul inside compute_total.
        let _ = merchant.create_invoice(
            &cashier_auth,
            vector[variant_id],
            vector[2],
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

#[test, expected_failure(abort_code = merchant::EInvoiceNotFound)]
fun pay_unknown_invoice_aborts() {
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

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let ac = scenario.take_shared<AccessControl<MERCHANT>>();

        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);

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

        // No invoice was created — `pay`'s `contains` guard aborts `EInvoiceNotFound`.
        let phantom = object::id_from_address(@0xDEADBEEF);
        merchant.pay<TEST_USD>(
            phantom,
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

#[test, expected_failure(abort_code = merchant::EInvoiceNotFound)]
fun pay_with_coin_unknown_invoice_aborts() {
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

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let ac = scenario.take_shared<AccessControl<MERCHANT>>();

        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);

        scenario.next_tx(CUSTOMER);
        let customer_account_shared = scenario.take_shared_by_id<Account>(customer_account_id);
        let payment_coin = coin::mint(&mut test_usd_cap, 500, scenario.ctx());

        // No invoice was created — aborts `EInvoiceNotFound`.
        let phantom = object::id_from_address(@0xDEADBEEF);
        merchant.pay_with_coin<TEST_USD>(
            phantom,
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

#[test, expected_failure(abort_code = merchant::EInvoiceNotFound)]
fun cancel_invoice_unknown_id_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(ns, PAYOUT, scenario.ctx());

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);

        let test_clock = clock::create_for_testing(scenario.ctx());

        // No invoice with this ID — aborts `EInvoiceNotFound`.
        let phantom = object::id_from_address(@0xDEADBEEF);
        merchant.cancel_invoice(phantom, &test_clock);

        // Unreachable cleanup.
        test_scenario::return_shared(merchant);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}
