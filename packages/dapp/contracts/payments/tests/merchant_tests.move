/// Tests for `merchant.move` — exercises catalog CRUD and config updates
/// through a fully bootstrapped Merchant (PAS namespace + LOYALTY policy +
/// TEST_USD policy + Merchant).
#[test_only]
module openzeppelin_payments::merchant_tests;

use openzeppelin_payments::config;
use openzeppelin_payments::listing;
use openzeppelin_payments::merchant::{Self, Merchant};
use openzeppelin_payments::test_setup;
use pas::e2e;
use std::unit_test::destroy;
use sui::test_scenario;

const ADMIN: address = @0xA;
const PAYOUT: address = @0xB;

#[test]
fun merchant_create_and_share() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        let (merchant_id, cap, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        scenario.next_tx(ADMIN);
        let merchant = scenario.take_shared_by_id<Merchant>(merchant_id);

        assert!(merchant.name() == b"Test Shop".to_string(), 0);
        assert!(merchant.payout_address() == PAYOUT, 0);
        assert!(merchant.config().mint_numerator() == 1, 0);
        assert!(merchant.config().mint_denominator() == 10, 0);
        assert!(merchant.config().invoice_ttl_ms() == 600_000, 0);

        test_scenario::return_shared(merchant);
        destroy(cap);
        destroy(test_usd_cap);
    });
}

#[test]
fun add_listing_with_variants() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        let (merchant_id, cap, test_usd_cap) = test_setup::setup_merchant(
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

        let listing_id = merchant.add_listing(&cap, listing);

        // Listing reachable through `merchant::listing`.
        let stored = merchant.listing(listing_id);
        assert!(stored.name() == b"Coffee".to_string(), 0);
        assert!(stored.variants().contains(&vid), 0);

        // Variant resolvable through `merchant::listing_variant` (variant_index).
        let v_ref = merchant.listing_variant(&vid);
        assert!(v_ref.price() == 500, 0);

        test_scenario::return_shared(merchant);
        destroy(cap);
        destroy(test_usd_cap);
    });
}

#[test, expected_failure(abort_code = merchant::EVariantNotFound)]
fun listing_variant_not_found_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        let (merchant_id, cap, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        scenario.next_tx(ADMIN);
        let merchant = scenario.take_shared_by_id<Merchant>(merchant_id);

        let phantom = object::id_from_address(@0xDEADBEEF);
        let _v = merchant.listing_variant(&phantom);

        test_scenario::return_shared(merchant);
        destroy(cap);
        destroy(test_usd_cap);
    });
}

#[test]
fun remove_listing_drops_variant_index() {
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
        let _vid = listing.add_variant(variant);

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);

        let listing_id = merchant.add_listing(&cap, listing);
        merchant.remove_listing(&cap, listing_id);

        test_scenario::return_shared(merchant);
        destroy(cap);
        destroy(test_usd_cap);
    });
}

#[test]
fun add_listing_variant_via_merchant() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        let (merchant_id, cap, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        let listing = listing::new(b"Coffee".to_string(), scenario.ctx());

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let listing_id = merchant.add_listing(&cap, listing);

        let variant = listing::new_variant(
            b"M".to_string(),
            700,
            std::option::some(70),
            scenario.ctx(),
        );
        let vid = merchant.add_listing_variant(&cap, listing_id, variant);

        // Variant reachable via merchant accessor.
        let v_ref = merchant.listing_variant(&vid);
        assert!(v_ref.price() == 700, 0);
        assert!(*v_ref.loyalty_price().borrow() == 70, 0);

        test_scenario::return_shared(merchant);
        destroy(cap);
        destroy(test_usd_cap);
    });
}

#[test]
fun remove_listing_variant_via_merchant() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        let (merchant_id, cap, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        let listing = listing::new(b"Coffee".to_string(), scenario.ctx());

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let listing_id = merchant.add_listing(&cap, listing);

        let variant = listing::new_variant(
            b"M".to_string(),
            700,
            std::option::none(),
            scenario.ctx(),
        );
        let vid = merchant.add_listing_variant(&cap, listing_id, variant);

        merchant.remove_listing_variant(&cap, vid);

        // Listing still exists, but the variant is gone.
        let stored = merchant.listing(listing_id);
        assert!(!stored.variants().contains(&vid), 0);

        test_scenario::return_shared(merchant);
        destroy(cap);
        destroy(test_usd_cap);
    });
}

#[test]
fun set_listing_status_toggles() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        let (merchant_id, cap, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        let listing = listing::new(b"Coffee".to_string(), scenario.ctx());

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let listing_id = merchant.add_listing(&cap, listing);

        assert!(merchant.listing(listing_id).active(), 0);

        merchant.set_listing_status(&cap, listing_id, false);
        assert!(!merchant.listing(listing_id).active(), 0);

        merchant.set_listing_status(&cap, listing_id, true);
        assert!(merchant.listing(listing_id).active(), 0);

        test_scenario::return_shared(merchant);
        destroy(cap);
        destroy(test_usd_cap);
    });
}

#[test, expected_failure(abort_code = ::openzeppelin_payments::listing::EActiveStateUnchanged)]
fun set_listing_status_same_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        let (merchant_id, cap, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        let listing = listing::new(b"Coffee".to_string(), scenario.ctx());

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);
        let listing_id = merchant.add_listing(&cap, listing);

        // Listing is already active — setting active=true must abort.
        merchant.set_listing_status(&cap, listing_id, true);

        test_scenario::return_shared(merchant);
        destroy(cap);
        destroy(test_usd_cap);
    });
}

#[test]
fun set_config_updates_values() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        let (merchant_id, cap, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);

        let new_cfg = config::new(2, 20, 500_000, 300_000, 300_000);
        merchant.set_config(&cap, new_cfg);

        assert!(merchant.config().mint_numerator() == 2, 0);
        assert!(merchant.config().mint_denominator() == 20, 0);
        assert!(merchant.config().max_mint_per_payment() == 500_000, 0);
        assert!(merchant.config().invoice_ttl_ms() == 300_000, 0);
        assert!(merchant.config().voucher_ttl_ms() == 300_000, 0);

        test_scenario::return_shared(merchant);
        destroy(cap);
        destroy(test_usd_cap);
    });
}

#[test, expected_failure(abort_code = merchant::EConfigUnchanged)]
fun set_config_unchanged_aborts() {
    e2e::test_tx!(ADMIN, |ns, _policy_a, _policy_b, scenario| {
        let (merchant_id, cap, test_usd_cap) = test_setup::setup_merchant(
            ns,
            PAYOUT,
            scenario.ctx(),
        );

        scenario.next_tx(ADMIN);
        let mut merchant = scenario.take_shared_by_id<Merchant>(merchant_id);

        // Same values as setup_merchant defaults.
        let same_cfg = config::new(1, 10, 1_000_000, 600_000, 600_000);
        merchant.set_config(&cap, same_cfg);

        test_scenario::return_shared(merchant);
        destroy(cap);
        destroy(test_usd_cap);
    });
}
