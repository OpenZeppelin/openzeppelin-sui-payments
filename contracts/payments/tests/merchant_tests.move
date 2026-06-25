/// Tests for `merchant.move` — exercises catalog CRUD and config updates
/// through a fully bootstrapped Merchant + `AccessControl<MERCHANT>` registry.
#[test_only]
module openzeppelin_payments::merchant_tests;

use openzeppelin_access::access_control::AccessControl;
use openzeppelin_payments::config;
use openzeppelin_payments::events;
use openzeppelin_payments::listing;
use openzeppelin_payments::loyalty::{Self, LOYALTY};
use openzeppelin_payments::merchant::{Self, Merchant, MERCHANT, MerchantRole, CatalogManagerRole};
use openzeppelin_payments::test_helpers::assert_emitted;
use openzeppelin_payments::test_setup::{Self, TEST_USD};
use pas::e2e;
use std::unit_test::{assert_eq, destroy};
use sui::coin;
use sui::test_scenario;

const ADMIN: address = @0xA;
const PAYOUT: address = @0xB;

#[test]
fun merchant_create_and_share() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        scenario.next_tx(ADMIN);
        let merchant = scenario.take_shared_by_id<Merchant>(merchant_id);

        assert_eq!(*merchant.name(), b"Test Shop".to_string());
        assert_eq!(merchant.payout_address(), PAYOUT);
        assert_eq!(merchant.config().loyalty_coefficient(), config::loyalty_float_scaling() / 10);
        assert_eq!(merchant.config().max_loyalty_per_payment(), 1_000_000);
        assert_eq!(merchant.config().invoice_ttl_ms(), 600_000);
        assert_eq!(merchant.config().voucher_ttl_ms(), 600_000);

        test_scenario::return_shared(merchant);
        destroy(test_usd_cap);
    });
}

#[test]
fun add_listing_with_variants() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        let mut listing = listing::new(b"Coffee".to_string(), scenario.ctx());
        let variant = listing::new_variant(
            b"Small".to_string(),
            500,
            std::option::none(),
            scenario.ctx(),
        );
        let vid = listing.add_variant(variant);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());

        let listing_id = merchant.add_listing(&catalog_auth, listing);

        // `ListingAdded` was emitted with the listing ID.
        assert_emitted!(events::listing_added(listing_id));

        let stored = merchant.listing(listing_id);
        assert_eq!(*stored.name(), b"Coffee".to_string());
        assert!(stored.variants().contains(&vid));

        let v_ref = merchant.listing_variant(&vid);
        assert_eq!(v_ref.price(), 500);

        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        destroy(test_usd_cap);
    });
}

#[test, expected_failure(abort_code = merchant::EVariantNotFound)]
fun listing_variant_not_found_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        scenario.next_tx(ADMIN);
        let merchant = scenario.take_shared_by_id<Merchant>(merchant_id);

        let phantom = object::id_from_address(@0xDEADBEEF);
        let _v = merchant.listing_variant(&phantom);

        test_scenario::return_shared(merchant);
        destroy(test_usd_cap);
    });
}

#[test]
fun remove_listing_drops_variant_index() {
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
        let _vid = listing.add_variant(variant);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());

        let listing_id = merchant.add_listing(&catalog_auth, listing);
        merchant.remove_listing(&catalog_auth, listing_id);

        // `ListingRemoved` was emitted with the listing ID.
        assert_emitted!(events::listing_removed(listing_id));

        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        destroy(test_usd_cap);
    });
}

#[test]
fun add_listing_variant_via_merchant() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        let listing = listing::new(b"Coffee".to_string(), scenario.ctx());

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());

        let listing_id = merchant.add_listing(&catalog_auth, listing);

        let variant = listing::new_variant(
            b"M".to_string(),
            700,
            std::option::some(70),
            scenario.ctx(),
        );
        let vid = merchant.add_listing_variant(&catalog_auth, listing_id, variant);

        // `VariantAdded` was emitted with the parent listing + new variant IDs.
        assert_emitted!(events::variant_added(listing_id, vid));

        let v_ref = merchant.listing_variant(&vid);
        assert_eq!(v_ref.price(), 700);
        assert_eq!(*v_ref.loyalty_price().borrow(), 70);

        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        destroy(test_usd_cap);
    });
}

#[test]
fun remove_listing_variant_via_merchant() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        let listing = listing::new(b"Coffee".to_string(), scenario.ctx());

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());

        let listing_id = merchant.add_listing(&catalog_auth, listing);

        let variant = listing::new_variant(
            b"M".to_string(),
            700,
            std::option::none(),
            scenario.ctx(),
        );
        let vid = merchant.add_listing_variant(&catalog_auth, listing_id, variant);

        merchant.remove_listing_variant(&catalog_auth, vid);

        // `VariantRemoved` was emitted with the parent listing + removed variant IDs.
        assert_emitted!(events::variant_removed(listing_id, vid));

        let stored = merchant.listing(listing_id);
        assert!(!stored.variants().contains(&vid));

        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        destroy(test_usd_cap);
    });
}

#[test]
fun set_listing_status_toggles() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        let listing = listing::new(b"Coffee".to_string(), scenario.ctx());

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());

        let listing_id = merchant.add_listing(&catalog_auth, listing);

        assert!(merchant.listing(listing_id).active());

        merchant.set_listing_status(&catalog_auth, listing_id, false);
        assert!(!merchant.listing(listing_id).active());
        // `ListingStatusChanged` was emitted for the deactivation.
        assert_emitted!(events::listing_status_changed(listing_id, false));

        merchant.set_listing_status(&catalog_auth, listing_id, true);
        assert!(merchant.listing(listing_id).active());
        // ...and for the reactivation.
        assert_emitted!(events::listing_status_changed(listing_id, true));

        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        destroy(test_usd_cap);
    });
}

#[test, expected_failure(abort_code = ::openzeppelin_payments::listing::EActiveStateUnchanged)]
fun set_listing_status_same_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        let listing = listing::new(b"Coffee".to_string(), scenario.ctx());

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());

        let listing_id = merchant.add_listing(&catalog_auth, listing);

        // Already active — must abort.
        merchant.set_listing_status(&catalog_auth, listing_id, true);

        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        destroy(test_usd_cap);
    });
}

#[test]
fun update_config_updates_values() {
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
        ac.grant_role<MERCHANT, MerchantRole>(ADMIN, scenario.ctx());
        let merchant_auth = ac.new_auth<MERCHANT, MerchantRole>(scenario.ctx());

        // Build a second Currency for the new config — distinct from the one
        // setup_merchant consumed (each `new_test_currency` call uses its own
        // dummy CoinRegistry).
        let (currency, treasury) = test_setup::new_test_currency(1);
        let new_coefficient = config::loyalty_float_scaling() / 5; // 0.2 LOY per unit
        let new_cfg = config::new<TEST_USD>(
            &currency,
            @0xC0FFEE,
            new_coefficient,
            500_000,
            300_000,
            300_000,
        );
        merchant.update_config(&merchant_auth, new_cfg);

        assert_eq!(merchant.payout_address(), @0xC0FFEE);
        assert_eq!(merchant.config().loyalty_coefficient(), new_coefficient);
        assert_eq!(merchant.config().max_loyalty_per_payment(), 500_000);
        assert_eq!(merchant.config().invoice_ttl_ms(), 300_000);
        assert_eq!(merchant.config().voucher_ttl_ms(), 300_000);
        assert_emitted!(events::config_updated());

        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        destroy(currency);
        destroy(treasury);
        destroy(test_usd_cap);
    });
}

#[test, expected_failure(abort_code = merchant::EConfigUnchanged)]
fun update_config_unchanged_aborts() {
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
        ac.grant_role<MERCHANT, MerchantRole>(ADMIN, scenario.ctx());
        let merchant_auth = ac.new_auth<MERCHANT, MerchantRole>(scenario.ctx());

        // Same values as setup_merchant defaults — update_config aborts.
        let (currency, treasury) = test_setup::new_test_currency(1);
        let same_cfg = config::new<TEST_USD>(
            &currency,
            PAYOUT,
            config::loyalty_float_scaling() / 10,
            1_000_000,
            600_000,
            600_000,
        );
        merchant.update_config(&merchant_auth, same_cfg);

        // Unreachable cleanup.
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        destroy(currency);
        destroy(treasury);
        destroy(test_usd_cap);
    });
}

#[test]
fun update_display_updates_name_and_logo() {
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
        ac.grant_role<MERCHANT, MerchantRole>(ADMIN, scenario.ctx());
        let merchant_auth = ac.new_auth<MERCHANT, MerchantRole>(scenario.ctx());

        merchant.update_display(
            &merchant_auth,
            b"Renamed Shop".to_string(),
            std::option::some(b"https://example.com/logo.png".to_string()),
        );
        assert_eq!(*merchant.name(), b"Renamed Shop".to_string());
        assert_eq!(*merchant.logo_url().borrow(), b"https://example.com/logo.png".to_string());
        assert_emitted!(events::display_updated());

        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        destroy(test_usd_cap);
    });
}

#[test, expected_failure(abort_code = merchant::EDisplayUnchanged)]
fun update_display_unchanged_aborts() {
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
        ac.grant_role<MERCHANT, MerchantRole>(ADMIN, scenario.ctx());
        let merchant_auth = ac.new_auth<MERCHANT, MerchantRole>(scenario.ctx());

        // Same as setup_merchant defaults (name="Test Shop", logo=None) — must abort.
        merchant.update_display(&merchant_auth, b"Test Shop".to_string(), std::option::none());

        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        destroy(test_usd_cap);
    });
}

#[test, expected_failure(abort_code = merchant::EListingNotFound)]
fun remove_listing_unknown_id_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(ns, PAYOUT, scenario.ctx());

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());

        let phantom = object::id_from_address(@0xDEADBEEF);
        merchant.remove_listing(&catalog_auth, phantom);

        // Unreachable cleanup.
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        destroy(test_usd_cap);
    });
}

#[test, expected_failure(abort_code = merchant::EListingNotFound)]
fun set_listing_status_unknown_id_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(ns, PAYOUT, scenario.ctx());

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());

        let phantom = object::id_from_address(@0xDEADBEEF);
        merchant.set_listing_status(&catalog_auth, phantom, false);

        // Unreachable cleanup.
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        destroy(test_usd_cap);
    });
}

#[test, expected_failure(abort_code = merchant::EListingNotFound)]
fun add_listing_variant_unknown_id_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(ns, PAYOUT, scenario.ctx());

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());

        let phantom = object::id_from_address(@0xDEADBEEF);
        let v = listing::new_variant(b"S".to_string(), 500, std::option::none(), scenario.ctx());
        let _vid = merchant.add_listing_variant(&catalog_auth, phantom, v);

        // Unreachable cleanup.
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        destroy(test_usd_cap);
    });
}

#[test, expected_failure(abort_code = merchant::EVariantNotFound)]
fun remove_listing_variant_unknown_id_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(ns, PAYOUT, scenario.ctx());

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, CatalogManagerRole>(ADMIN, scenario.ctx());
        let catalog_auth = ac.new_auth<MERCHANT, CatalogManagerRole>(scenario.ctx());

        let phantom = object::id_from_address(@0xDEADBEEF);
        merchant.remove_listing_variant(&catalog_auth, phantom);

        // Unreachable cleanup.
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        destroy(test_usd_cap);
    });
}

#[test, expected_failure(abort_code = merchant::EListingNotFound)]
fun listing_getter_unknown_id_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(ns, PAYOUT, scenario.ctx());

        scenario.next_tx(ADMIN);
        let merchant = scenario.take_shared_by_id<Merchant>(merchant_id);

        let phantom = object::id_from_address(@0xDEADBEEF);
        let _ = merchant.listing(phantom);

        // Unreachable cleanup.
        test_scenario::return_shared(merchant);
        destroy(test_usd_cap);
    });
}

#[test, expected_failure(abort_code = merchant::EInvoiceNotFound)]
fun invoice_getter_unknown_id_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(ns, PAYOUT, scenario.ctx());

        scenario.next_tx(ADMIN);
        let merchant = scenario.take_shared_by_id<Merchant>(merchant_id);

        let phantom = object::id_from_address(@0xDEADBEEF);
        let _ = merchant.invoice(phantom);

        // Unreachable cleanup.
        test_scenario::return_shared(merchant);
        destroy(test_usd_cap);
    });
}

#[test, expected_failure(abort_code = merchant::EVoucherNotFound)]
fun voucher_getter_unknown_id_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(ns, PAYOUT, scenario.ctx());

        scenario.next_tx(ADMIN);
        let merchant = scenario.take_shared_by_id<Merchant>(merchant_id);

        let phantom = object::id_from_address(@0xDEADBEEF);
        let _ = merchant.voucher(phantom);

        // Unreachable cleanup.
        test_scenario::return_shared(merchant);
        destroy(test_usd_cap);
    });
}

#[test, expected_failure(abort_code = merchant::EEmptyName)]
fun create_empty_name_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());

        // Build the LOYALTY bundle + config inline (mirror of `setup_merchant`),
        // then create a Merchant with an empty name — aborts on `EEmptyName`.
        let loyalty_cap = coin::create_treasury_cap_for_testing<LOYALTY>(scenario.ctx());
        let loyalty_bundle = loyalty::create(ns, loyalty_cap);
        let (currency, treasury) = test_setup::new_test_currency(1);
        let cfg = config::new<TEST_USD>(
            &currency,
            PAYOUT,
            config::loyalty_float_scaling() / 10,
            1_000_000,
            600_000,
            600_000,
        );

        let _m = merchant::create(
            loyalty_bundle,
            cfg,
            b"".to_string(),
            std::option::none(),
            scenario.ctx(),
        );

        // Unreachable.
        merchant::share(_m);
        destroy(currency);
        destroy(treasury);
    });
}

#[test, expected_failure(abort_code = merchant::EEmptyName)]
fun update_display_empty_name_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        merchant::init_for_testing(scenario.ctx());
        let (merchant_id, test_usd_cap) = test_setup::setup_merchant(ns, PAYOUT, scenario.ctx());

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let mut ac = scenario.take_shared<AccessControl<MERCHANT>>();
        ac.grant_role<MERCHANT, MerchantRole>(ADMIN, scenario.ctx());
        let merchant_auth = ac.new_auth<MERCHANT, MerchantRole>(scenario.ctx());

        merchant.update_display(&merchant_auth, b"".to_string(), std::option::none());

        // Unreachable cleanup.
        test_scenario::return_shared(merchant);
        test_scenario::return_shared(ac);
        destroy(test_usd_cap);
    });
}
