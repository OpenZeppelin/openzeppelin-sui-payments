/// E2E tests for the voucher + redeem flow.
#[test_only]
module openzeppelin_payments::redemption_tests;

use openzeppelin_access::access_control::AccessControl;
use openzeppelin_payments::events;
use openzeppelin_payments::listing;
use openzeppelin_payments::loyalty::LOYALTY;
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
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::clock;
use sui::coin;
use sui::test_scenario;

const ADMIN: address = @0xA;
const PAYOUT: address = @0xB;
const CUSTOMER: address = @0xCAFE;
const OTHER: address = @0xC0FFEE;

#[test]
fun redemption_happy_path() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        // Customer PAS account. We fund it with LOYALTY by running a real
        // payment first (paying 500 TEST_USD mints 50 LOYALTY at the default
        // 1/10 rate). This is supply-tracked LOYALTY, which `redeem`'s
        // `balance::decrease_supply` requires (a `create_for_testing` balance
        // would underflow the treasury supply counter).
        let customer_account_id = ns.account_address(CUSTOMER).to_id();
        let customer_account = account::create(ns, CUSTOMER);
        customer_account.deposit_balance(balance::create_for_testing<TEST_USD>(10_000));
        customer_account.share();

        let payout_account_id = ns.account_address(PAYOUT).to_id();
        account::create_and_share(ns, PAYOUT);

        // Catalog: one listing with a variant priced 500 stablecoin units and 50 LOYALTY.
        let mut listing = listing::new(b"Free Drink".to_string(), scenario.ctx());
        let variant = listing::new_variant(
            b"Small".to_string(),
            500,
            std::option::some(50),
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

        // Issue + pay an invoice to mint 50 LOYALTY into the customer's account.
        let invoice_id = merchant.create_invoice(
            &cashier_auth,
            vector[variant_id],
            vector[1],
            b"fund",
            &test_clock,
            scenario.ctx(),
        );

        scenario.next_tx(CUSTOMER);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );
        let payout_account_shared = scenario.take_shared_by_id<Account>(payout_account_id);
        let test_usd_policy = test_setup::take_test_usd_policy(scenario);
        let loyalty_policy = test_setup::take_loyalty_policy(scenario);

        let pay_auth = account::new_auth(scenario.ctx());
        let mut send_req = customer_account_shared.send_balance<TEST_USD>(
            &pay_auth,
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

        // Customer: build unlock request, then voucher.
        let customer_auth = account::new_auth(scenario.ctx());
        let unlock_req = customer_account_shared.unlock_balance<LOYALTY>(
            &customer_auth,
            50,
            scenario.ctx(),
        );

        let voucher_id = merchant.create_voucher(
            unlock_req,
            &loyalty_policy,
            vector[variant_id],
            vector[1],
            &test_clock,
            scenario.ctx(),
        );

        // `VoucherCreated` was emitted with the issuance ID (same tx as create_voucher).
        assert_emitted!(events::voucher_created(voucher_id));

        // Merchant redeems. Capture LOYALTY supply before/after to confirm
        // the redeem path actually burns from the TreasuryCap-tracked supply.
        scenario.next_tx(ADMIN);
        let supply_before = coin::total_supply(merchant.loyalty().treasury_cap());
        merchant.redeem(&cashier_auth, voucher_id, &test_clock);
        let supply_after = coin::total_supply(merchant.loyalty().treasury_cap());
        assert_eq!(supply_before - supply_after, 50);

        // `VoucherRedeemed` was emitted with the expected payload.
        assert_emitted!(events::voucher_redeemed(voucher_id, CUSTOMER, 50, 1_000_000));

        // Receipt is stored in the merchant's receipt table, keyed by voucher id.
        let r = merchant.voucher_receipt(voucher_id);
        assert_eq!(receipt::amount(r), 50);
        assert_eq!(receipt::timestamp_ms(r), 1_000_000);

        test_setup::return_loyalty_policy(loyalty_policy);
        test_setup::return_test_usd_policy(test_usd_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        test_scenario::return_shared(payout_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = merchant::EVoucherExpired)]
fun redeem_after_expiry_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
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
            500,
            std::option::some(50),
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

        scenario.next_tx(CUSTOMER);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );
        let loyalty_policy = test_setup::take_loyalty_policy(scenario);

        let customer_auth = account::new_auth(scenario.ctx());
        let unlock_req = customer_account_shared.unlock_balance<LOYALTY>(
            &customer_auth,
            50,
            scenario.ctx(),
        );

        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);

        let voucher_id = merchant.create_voucher(
            unlock_req,
            &loyalty_policy,
            vector[variant_id],
            vector[1],
            &test_clock,
            scenario.ctx(),
        );

        // Advance past voucher_ttl_ms (600_000).
        test_clock.set_for_testing(2_000_000);

        scenario.next_tx(ADMIN);
        merchant.redeem(&cashier_auth, voucher_id, &test_clock);

        // Unreachable cleanup.
        test_setup::return_loyalty_policy(loyalty_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test]
fun cancel_voucher_returns_funds() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
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
            500,
            std::option::some(50),
            scenario.ctx(),
        );
        let variant_id = listing.add_variant(variant);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());

        let _ = merchant.add_listing(&catalog_auth, listing);

        scenario.next_tx(CUSTOMER);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );
        let loyalty_policy = test_setup::take_loyalty_policy(scenario);

        let customer_auth = account::new_auth(scenario.ctx());
        let unlock_req = customer_account_shared.unlock_balance<LOYALTY>(
            &customer_auth,
            50,
            scenario.ctx(),
        );

        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);
        let voucher_id = merchant.create_voucher(
            unlock_req,
            &loyalty_policy,
            vector[variant_id],
            vector[1],
            &test_clock,
            scenario.ctx(),
        );

        // Past expiry, permissionless cancel by another address.
        test_clock.set_for_testing(2_000_000);
        scenario.next_tx(@0xDEAD);
        merchant.cancel_voucher(voucher_id, &customer_account_shared, &test_clock);

        // `VoucherCanceled` was emitted with the expected payload.
        assert_emitted!(events::voucher_canceled(voucher_id, CUSTOMER, 50));

        test_setup::return_loyalty_policy(loyalty_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = merchant::ENoLoyaltyPrice)]
fun voucher_without_loyalty_price_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        let customer_account_id = ns.account_address(CUSTOMER).to_id();
        let customer_account = account::create(ns, CUSTOMER);
        customer_account.deposit_balance(balance::create_for_testing<LOYALTY>(100));
        customer_account.share();

        // Variant has only a stablecoin price (no loyalty_price) — should be
        // unredeemable for LOYALTY.
        let mut listing = listing::new(b"Cash-only Drink".to_string(), scenario.ctx());
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
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());

        let _ = merchant.add_listing(&catalog_auth, listing);

        scenario.next_tx(CUSTOMER);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );
        let loyalty_policy = test_setup::take_loyalty_policy(scenario);

        let customer_auth = account::new_auth(scenario.ctx());
        let unlock_req = customer_account_shared.unlock_balance<LOYALTY>(
            &customer_auth,
            50,
            scenario.ctx(),
        );

        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);

        // Aborts with `merchant::ENoLoyaltyPrice` — variant has no loyalty_price.
        let _voucher_id = merchant.create_voucher(
            unlock_req,
            &loyalty_policy,
            vector[variant_id],
            vector[1],
            &test_clock,
            scenario.ctx(),
        );

        // Unreachable cleanup.
        test_setup::return_loyalty_policy(loyalty_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = merchant::ENoItems)]
fun redemption_empty_items_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        let customer_account_id = ns.account_address(CUSTOMER).to_id();
        let customer_account = account::create(ns, CUSTOMER);
        customer_account.deposit_balance(balance::create_for_testing<LOYALTY>(100));
        customer_account.share();

        scenario.next_tx(CUSTOMER);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );
        let loyalty_policy = test_setup::take_loyalty_policy(scenario);

        let customer_auth = account::new_auth(scenario.ctx());
        let unlock_req = customer_account_shared.unlock_balance<LOYALTY>(
            &customer_auth,
            50,
            scenario.ctx(),
        );

        let test_clock = clock::create_for_testing(scenario.ctx());

        // Empty vectors — aborts on `ENoItems`.
        let _voucher_id = merchant.create_voucher(
            unlock_req,
            &loyalty_policy,
            vector[],
            vector[],
            &test_clock,
            scenario.ctx(),
        );

        // Unreachable cleanup.
        test_setup::return_loyalty_policy(loyalty_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(customer_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = merchant::ELengthMismatch)]
fun redemption_length_mismatch_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        let customer_account_id = ns.account_address(CUSTOMER).to_id();
        let customer_account = account::create(ns, CUSTOMER);
        customer_account.deposit_balance(balance::create_for_testing<LOYALTY>(100));
        customer_account.share();

        // One variant in the catalog, but we'll pass mismatched-length vectors.
        let mut listing = listing::new(b"Drink".to_string(), scenario.ctx());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::some(50),
            scenario.ctx(),
        );
        let variant_id = listing.add_variant(variant);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());

        let _ = merchant.add_listing(&catalog_auth, listing);

        scenario.next_tx(CUSTOMER);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );
        let loyalty_policy = test_setup::take_loyalty_policy(scenario);

        let customer_auth = account::new_auth(scenario.ctx());
        let unlock_req = customer_account_shared.unlock_balance<LOYALTY>(
            &customer_auth,
            50,
            scenario.ctx(),
        );

        let test_clock = clock::create_for_testing(scenario.ctx());

        // 1 variant id, 2 quantities — aborts on `ELengthMismatch`.
        let _voucher_id = merchant.create_voucher(
            unlock_req,
            &loyalty_policy,
            vector[variant_id],
            vector[1, 2],
            &test_clock,
            scenario.ctx(),
        );

        // Unreachable cleanup.
        test_setup::return_loyalty_policy(loyalty_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = merchant::EListingInactive)]
fun redemption_inactive_listing_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
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
            500,
            std::option::some(50),
            scenario.ctx(),
        );
        let variant_id = listing.add_variant(variant);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());

        let listing_id = merchant.add_listing(&catalog_auth, listing);
        // Deactivate after adding — now the variant should not be redeemable.
        merchant.set_listing_status(&catalog_auth, listing_id, false);

        scenario.next_tx(CUSTOMER);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );
        let loyalty_policy = test_setup::take_loyalty_policy(scenario);

        let customer_auth = account::new_auth(scenario.ctx());
        let unlock_req = customer_account_shared.unlock_balance<LOYALTY>(
            &customer_auth,
            50,
            scenario.ctx(),
        );

        let test_clock = clock::create_for_testing(scenario.ctx());

        // Variant belongs to a deactivated listing — aborts on `EListingInactive`.
        let _voucher_id = merchant.create_voucher(
            unlock_req,
            &loyalty_policy,
            vector[variant_id],
            vector[1],
            &test_clock,
            scenario.ctx(),
        );

        // Unreachable cleanup.
        test_setup::return_loyalty_policy(loyalty_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = merchant::EWrongCustomer)]
fun cancel_wrong_customer_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        let customer_account_id = ns.account_address(CUSTOMER).to_id();
        let customer_account = account::create(ns, CUSTOMER);
        customer_account.deposit_balance(balance::create_for_testing<LOYALTY>(100));
        customer_account.share();

        // Foreign account owned by OTHER — used to attempt the cancel.
        let other_account_id = ns.account_address(OTHER).to_id();
        account::create_and_share(ns, OTHER);

        let mut listing = listing::new(b"Drink".to_string(), scenario.ctx());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::some(50),
            scenario.ctx(),
        );
        let variant_id = listing.add_variant(variant);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());

        let _ = merchant.add_listing(&catalog_auth, listing);

        scenario.next_tx(CUSTOMER);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );
        let other_account_shared = scenario.take_shared_by_id<Account>(other_account_id);
        let loyalty_policy = test_setup::take_loyalty_policy(scenario);

        let customer_auth = account::new_auth(scenario.ctx());
        let unlock_req = customer_account_shared.unlock_balance<LOYALTY>(
            &customer_auth,
            50,
            scenario.ctx(),
        );

        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);

        let voucher_id = merchant.create_voucher(
            unlock_req,
            &loyalty_policy,
            vector[variant_id],
            vector[1],
            &test_clock,
            scenario.ctx(),
        );

        // Past expiry, attempt cancel with the wrong customer account.
        test_clock.set_for_testing(2_000_000);
        scenario.next_tx(@0xDEAD);
        // Aborts with `merchant::EWrongCustomer`.
        merchant.cancel_voucher(voucher_id, &other_account_shared, &test_clock);

        // Unreachable cleanup.
        test_setup::return_loyalty_policy(loyalty_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        test_scenario::return_shared(other_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test]
fun redemption_receipt_stored_in_merchant() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        // Fund the customer's LOYALTY by running a real payment first (paying
        // 500 TEST_USD mints 50 supply-tracked LOYALTY at the default 1/10 rate).
        let customer_account_id = ns.account_address(CUSTOMER).to_id();
        let customer_account = account::create(ns, CUSTOMER);
        customer_account.deposit_balance(balance::create_for_testing<TEST_USD>(10_000));
        customer_account.share();

        let payout_account_id = ns.account_address(PAYOUT).to_id();
        account::create_and_share(ns, PAYOUT);

        let mut listing = listing::new(b"Drink".to_string(), scenario.ctx());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::some(50),
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

        // Issue + pay an invoice to mint 50 LOYALTY into the customer's account.
        let invoice_id = merchant.create_invoice(
            &cashier_auth,
            vector[variant_id],
            vector[1],
            b"fund",
            &test_clock,
            scenario.ctx(),
        );

        scenario.next_tx(CUSTOMER);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );
        let payout_account_shared = scenario.take_shared_by_id<Account>(payout_account_id);
        let test_usd_policy = test_setup::take_test_usd_policy(scenario);
        let loyalty_policy = test_setup::take_loyalty_policy(scenario);

        let pay_auth = account::new_auth(scenario.ctx());
        let mut send_req = customer_account_shared.send_balance<TEST_USD>(
            &pay_auth,
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

        let customer_auth = account::new_auth(scenario.ctx());
        let unlock_req = customer_account_shared.unlock_balance<LOYALTY>(
            &customer_auth,
            50,
            scenario.ctx(),
        );

        let voucher_id = merchant.create_voucher(
            unlock_req,
            &loyalty_policy,
            vector[variant_id],
            vector[1],
            &test_clock,
            scenario.ctx(),
        );

        scenario.next_tx(ADMIN);
        merchant.redeem(&cashier_auth, voucher_id, &test_clock);

        // The receipt is stored in the merchant's receipt table, keyed by
        // voucher id. Read it back and verify it records the redemption.
        let r = merchant.voucher_receipt(voucher_id);
        assert_eq!(receipt::amount(r), 50);
        assert_eq!(receipt::voucher_id(r), voucher_id);

        test_setup::return_loyalty_policy(loyalty_policy);
        test_setup::return_test_usd_policy(test_usd_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        test_scenario::return_shared(payout_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = merchant::ENotExpired)]
fun cancel_voucher_before_expiry_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
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
            500,
            std::option::some(50),
            scenario.ctx(),
        );
        let variant_id = listing.add_variant(variant);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());

        let _ = merchant.add_listing(&catalog_auth, listing);

        scenario.next_tx(CUSTOMER);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );
        let loyalty_policy = test_setup::take_loyalty_policy(scenario);

        let customer_auth = account::new_auth(scenario.ctx());
        let unlock_req = customer_account_shared.unlock_balance<LOYALTY>(
            &customer_auth,
            50,
            scenario.ctx(),
        );

        let test_clock = clock::create_for_testing(scenario.ctx());
        let voucher_id = merchant.create_voucher(
            unlock_req,
            &loyalty_policy,
            vector[variant_id],
            vector[1],
            &test_clock,
            scenario.ctx(),
        );

        // Voucher is still live — `cancel_voucher` must abort with `ENotExpired`.
        scenario.next_tx(@0xDEAD);
        merchant.cancel_voucher(voucher_id, &customer_account_shared, &test_clock);

        // Unreachable cleanup.
        test_setup::return_loyalty_policy(loyalty_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = merchant::EZeroAmount)]
fun redemption_zero_amount_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
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
            500,
            std::option::some(50),
            scenario.ctx(),
        );
        let variant_id = listing.add_variant(variant);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());

        let _ = merchant.add_listing(&catalog_auth, listing);

        scenario.next_tx(CUSTOMER);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );
        let loyalty_policy = test_setup::take_loyalty_policy(scenario);

        let customer_auth = account::new_auth(scenario.ctx());
        // Unlock 0 LOYALTY — `EZeroAmount` should fire before EInvalidAmount.
        let unlock_req = customer_account_shared.unlock_balance<LOYALTY>(
            &customer_auth,
            0,
            scenario.ctx(),
        );

        let test_clock = clock::create_for_testing(scenario.ctx());
        let _voucher_id = merchant.create_voucher(
            unlock_req,
            &loyalty_policy,
            vector[variant_id],
            vector[1],
            &test_clock,
            scenario.ctx(),
        );

        // Unreachable cleanup.
        test_setup::return_loyalty_policy(loyalty_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = merchant::EInvalidAmount)]
fun redemption_amount_mismatch_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        let customer_account_id = ns.account_address(CUSTOMER).to_id();
        let customer_account = account::create(ns, CUSTOMER);
        customer_account.deposit_balance(balance::create_for_testing<LOYALTY>(100));
        customer_account.share();

        // Variant priced at 50 LOY per unit. Customer unlocks 49 — total
        // item cost (50 * 1 = 50) won't match unlocked amount.
        let mut listing = listing::new(b"Drink".to_string(), scenario.ctx());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::some(50),
            scenario.ctx(),
        );
        let variant_id = listing.add_variant(variant);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());

        let _ = merchant.add_listing(&catalog_auth, listing);

        scenario.next_tx(CUSTOMER);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );
        let loyalty_policy = test_setup::take_loyalty_policy(scenario);

        let customer_auth = account::new_auth(scenario.ctx());
        let unlock_req = customer_account_shared.unlock_balance<LOYALTY>(
            &customer_auth,
            49, // off-by-one against item total
            scenario.ctx(),
        );

        let test_clock = clock::create_for_testing(scenario.ctx());
        let _voucher_id = merchant.create_voucher(
            unlock_req,
            &loyalty_policy,
            vector[variant_id],
            vector[1],
            &test_clock,
            scenario.ctx(),
        );

        // Unreachable cleanup.
        test_setup::return_loyalty_policy(loyalty_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = merchant::EReceiptNotFound)]
fun prune_voucher_receipts_removes_receipt() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(ns, PAYOUT, scenario.ctx());

        // Fund LOYALTY by paying a real invoice first (mints 50 at the 1/10 rate).
        let customer_account_id = ns.account_address(CUSTOMER).to_id();
        let customer_account = account::create(ns, CUSTOMER);
        customer_account.deposit_balance(balance::create_for_testing<TEST_USD>(10_000));
        customer_account.share();

        let payout_account_id = ns.account_address(PAYOUT).to_id();
        account::create_and_share(ns, PAYOUT);

        let mut listing = listing::new(b"Free Drink".to_string(), scenario.ctx());
        let variant = listing::new_variant(
            b"Small".to_string(),
            500,
            std::option::some(50),
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
        let _ = merchant.add_listing(&catalog_auth, listing);

        let mut test_clock = clock::create_for_testing(scenario.ctx());
        test_clock.set_for_testing(1_000_000);
        let invoice_id = merchant.create_invoice(
            &cashier_auth,
            vector[variant_id],
            vector[1],
            b"fund",
            &test_clock,
            scenario.ctx(),
        );

        scenario.next_tx(CUSTOMER);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(customer_account_id);
        let payout_account_shared = scenario.take_shared_by_id<Account>(payout_account_id);
        let test_usd_policy = test_setup::take_test_usd_policy(scenario);
        let loyalty_policy = test_setup::take_loyalty_policy(scenario);

        let pay_auth = account::new_auth(scenario.ctx());
        let mut send_req = customer_account_shared.send_balance<TEST_USD>(
            &pay_auth,
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

        // Customer locks the 50 LOYALTY into a voucher.
        let customer_auth = account::new_auth(scenario.ctx());
        let unlock_req = customer_account_shared.unlock_balance<LOYALTY>(
            &customer_auth,
            50,
            scenario.ctx(),
        );
        let voucher_id = merchant.create_voucher(
            unlock_req,
            &loyalty_policy,
            vector[variant_id],
            vector[1],
            &test_clock,
            scenario.ctx(),
        );

        // Merchant redeems, then prunes the receipt; reading it aborts `EReceiptNotFound`.
        scenario.next_tx(ADMIN);
        merchant.redeem(&cashier_auth, voucher_id, &test_clock);
        merchant.prune_voucher_receipts(&merchant_auth, vector[voucher_id]);
        let _ = merchant.voucher_receipt(voucher_id);

        // Unreachable cleanup.
        test_setup::return_loyalty_policy(loyalty_policy);
        test_setup::return_test_usd_policy(test_usd_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        test_scenario::return_shared(payout_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = merchant::EVoucherNotFound)]
fun redeem_unknown_voucher_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(ns, PAYOUT, scenario.ctx());

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CashierRole>(ADMIN, scenario.ctx());
        let cashier_auth = ac.new_auth<MERCHANT, CashierRole>(scenario.ctx());

        let test_clock = clock::create_for_testing(scenario.ctx());

        // No voucher with this ID — aborts `EVoucherNotFound`.
        let phantom = object::id_from_address(@0xDEADBEEF);
        merchant.redeem(&cashier_auth, phantom, &test_clock);

        // Unreachable cleanup.
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = merchant::EVoucherNotFound)]
fun cancel_voucher_unknown_id_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(ns, PAYOUT, scenario.ctx());

        let customer_account_id = ns.account_address(CUSTOMER).to_id();
        account::create_and_share(ns, CUSTOMER);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let ac = scenario.take_shared<AccessControl<MERCHANT>>();

        let test_clock = clock::create_for_testing(scenario.ctx());

        scenario.next_tx(CUSTOMER);
        let customer_account_shared = scenario.take_shared_by_id<Account>(customer_account_id);

        // No voucher with this ID — aborts `EVoucherNotFound`.
        let phantom = object::id_from_address(@0xDEADBEEF);
        merchant.cancel_voucher(phantom, &customer_account_shared, &test_clock);

        // Unreachable cleanup.
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = merchant::EReceiptNotFound)]
fun prune_voucher_receipts_unknown_id_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(ns, PAYOUT, scenario.ctx());

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, MerchantRole>(ADMIN, scenario.ctx());
        let merchant_auth = ac.new_auth<MERCHANT, MerchantRole>(scenario.ctx());

        // No voucher receipt with this ID — aborts `EReceiptNotFound`.
        let phantom = object::id_from_address(@0xDEADBEEF);
        merchant.prune_voucher_receipts(&merchant_auth, vector[phantom]);

        // Unreachable cleanup.
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        destroy(test_usd_cap);
    });
}

#[test, expected_failure(abort_code = merchant::EZeroQuantity)]
fun create_voucher_zero_quantity_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(ns, PAYOUT, scenario.ctx());

        let customer_account_id = ns.account_address(CUSTOMER).to_id();
        let customer_account = account::create(ns, CUSTOMER);
        customer_account.deposit_balance(balance::create_for_testing<LOYALTY>(100));
        customer_account.share();

        let mut listing = listing::new(b"Drink".to_string(), scenario.ctx());
        let variant = listing::new_variant(
            b"S".to_string(),
            500,
            std::option::some(50),
            scenario.ctx(),
        );
        let variant_id = listing.add_variant(variant);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());

        let _ = merchant.add_listing(&catalog_auth, listing);

        scenario.next_tx(CUSTOMER);
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );
        let loyalty_policy = test_setup::take_loyalty_policy(scenario);

        let customer_auth = account::new_auth(scenario.ctx());
        let unlock_req = customer_account_shared.unlock_balance<LOYALTY>(
            &customer_auth,
            50,
            scenario.ctx(),
        );

        let test_clock = clock::create_for_testing(scenario.ctx());

        // Quantity 0 — aborts on `EZeroQuantity` during item pricing.
        let _voucher_id = merchant.create_voucher(
            unlock_req,
            &loyalty_policy,
            vector[variant_id],
            vector[0],
            &test_clock,
            scenario.ctx(),
        );

        // Unreachable cleanup.
        test_setup::return_loyalty_policy(loyalty_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}
