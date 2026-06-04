/// E2E tests for the voucher + redeem flow.
#[test_only]
module openzeppelin_payments::redemption_tests;

use openzeppelin_access::access_control::AccessControl;
use openzeppelin_payments::listing;
use openzeppelin_payments::loyalty::LOYALTY;
use openzeppelin_payments::merchant::{Self, Merchant, MERCHANT, CashierRole, CatalogManagerRole};
use openzeppelin_payments::receipt::{Self, Receipt, Redemption};
use openzeppelin_payments::redemption::{Self, Voucher};
use openzeppelin_payments::test_setup;
use pas::account::{Self, Account};
use pas::e2e;
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::clock;
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

        // Customer PAS account (unfunded for now; we mint LOYALTY via the
        // merchant TreasuryCap below so the supply counter matches circulation
        // — `balance::decrease_supply` asserts on this in `redeem`).
        let customer_account_id = ns.account_address(CUSTOMER).to_id();
        account::create_and_share(ns, CUSTOMER);

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
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );

        let _ = merchant.add_listing(&catalog_auth, listing);

        // Mint LOYALTY for the customer via the merchant-held TreasuryCap.
        let loyalty_bal = merchant.loyalty_mut().treasury_cap_mut().mint_balance(100);
        customer_account_shared.deposit_balance(loyalty_bal);

        // Customer: build unlock request, then voucher.
        scenario.next_tx(CUSTOMER);
        let loyalty_policy = test_setup::take_loyalty_policy(scenario);

        let customer_auth = account::new_auth(scenario.ctx());
        let unlock_req = customer_account_shared.unlock_balance<LOYALTY>(
            &customer_auth,
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
        redemption::redeem(v_shared, &cashier_auth, &mut merchant, &test_clock, scenario.ctx());

        // Customer receives the RedemptionReceipt.
        scenario.next_tx(CUSTOMER);
        let r = scenario.take_from_sender<Receipt<Redemption>>();
        assert_eq!(receipt::amount(&r), 50);
        assert_eq!(receipt::timestamp_ms(&r), 1_000_000);

        destroy(r);
        test_setup::return_loyalty_policy(loyalty_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = redemption::EVoucherExpired)]
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
        redemption::redeem(v_shared, &cashier_auth, &mut merchant, &test_clock, scenario.ctx());

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
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = receipt::ENoLoyaltyPrice)]
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

        // Aborts with `receipt::ENoLoyaltyPrice` — variant has no loyalty_price.
        let voucher = redemption::new(
            &merchant,
            unlock_req,
            &loyalty_policy,
            vector[variant_id],
            vector[1],
            &test_clock,
            scenario.ctx(),
        );
        redemption::share(voucher);

        // Unreachable cleanup.
        test_setup::return_loyalty_policy(loyalty_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = redemption::ENoItems)]
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
        let merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
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
        let voucher = redemption::new(
            &merchant,
            unlock_req,
            &loyalty_policy,
            vector[],
            vector[],
            &test_clock,
            scenario.ctx(),
        );
        redemption::share(voucher);

        // Unreachable cleanup.
        test_setup::return_loyalty_policy(loyalty_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(customer_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = redemption::ELengthMismatch)]
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
        let voucher = redemption::new(
            &merchant,
            unlock_req,
            &loyalty_policy,
            vector[variant_id],
            vector[1, 2],
            &test_clock,
            scenario.ctx(),
        );
        redemption::share(voucher);

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
        let voucher = redemption::new(
            &merchant,
            unlock_req,
            &loyalty_policy,
            vector[variant_id],
            vector[1],
            &test_clock,
            scenario.ctx(),
        );
        redemption::share(voucher);

        // Unreachable cleanup.
        test_setup::return_loyalty_policy(loyalty_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}

#[test, expected_failure(abort_code = redemption::EWrongCustomer)]
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

        // Past expiry, attempt cancel with the wrong customer account.
        test_clock.set_for_testing(2_000_000);
        scenario.next_tx(@0xDEAD);
        let v_shared = scenario.take_shared_by_id<Voucher>(voucher_id);
        // Aborts with `redemption::EWrongCustomer`.
        redemption::cancel(v_shared, &other_account_shared, &test_clock);

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
fun destroy_redemption_receipt_succeeds() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        let customer_account_id = ns.account_address(CUSTOMER).to_id();
        account::create_and_share(ns, CUSTOMER);

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
        let mut customer_account_shared = scenario.take_shared_by_id<Account>(
            customer_account_id,
        );

        let _ = merchant.add_listing(&catalog_auth, listing);

        // Mint LOYALTY for the customer via the merchant-held TreasuryCap.
        let loyalty_bal = merchant.loyalty_mut().treasury_cap_mut().mint_balance(100);
        customer_account_shared.deposit_balance(loyalty_bal);

        scenario.next_tx(CUSTOMER);
        let loyalty_policy = test_setup::take_loyalty_policy(scenario);
        let customer_auth = account::new_auth(scenario.ctx());
        let unlock_req = customer_account_shared.unlock_balance<LOYALTY>(
            &customer_auth,
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

        scenario.next_tx(ADMIN);
        let v_shared = scenario.take_shared_by_id<Voucher>(voucher_id);
        redemption::redeem(v_shared, &cashier_auth, &mut merchant, &test_clock, scenario.ctx());

        // Customer voluntarily discards their receipt.
        scenario.next_tx(CUSTOMER);
        let r = scenario.take_from_sender<Receipt<Redemption>>();
        receipt::destroy(r);

        test_setup::return_loyalty_policy(loyalty_policy);
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        test_scenario::return_shared(customer_account_shared);
        destroy(test_usd_cap);
        destroy(test_clock);
    });
}
