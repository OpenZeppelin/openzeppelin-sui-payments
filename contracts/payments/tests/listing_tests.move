/// Tests for `listing.move` — pure data-structure tests for `Listing` and
/// `Variant`. No PAS or Merchant setup needed since `listing::new` is `public`
/// and `add_variant` / `remove_variant` / `set_active` are `public(package)`,
/// callable from package-internal test code.
#[test_only]
module openzeppelin_payments::listing_tests;

use openzeppelin_payments::listing;
use std::unit_test::destroy;
use sui::test_scenario;

#[test]
fun new_listing_starts_empty_and_active() {
    let mut scenario = test_scenario::begin(@0xA);

    let listing = listing::new(b"Coffee".to_string(), scenario.ctx());
    assert!(listing.name() == b"Coffee".to_string(), 0);
    assert!(listing.active(), 0);
    assert!(listing.variants().is_empty(), 0);

    destroy(listing);
    scenario.end();
}

#[test, expected_failure(abort_code = listing::EEmptyName)]
fun new_listing_empty_name_aborts() {
    let mut scenario = test_scenario::begin(@0xA);
    let listing = listing::new(b"".to_string(), scenario.ctx());
    destroy(listing);
    scenario.end();
}

#[test]
fun add_variant_inserts_and_returns_id() {
    let mut scenario = test_scenario::begin(@0xA);

    let mut listing = listing::new(b"Coffee".to_string(), scenario.ctx());
    let variant = listing::new_variant(
        b"Small".to_string(),
        500,
        std::option::none(),
        scenario.ctx(),
    );
    let vid = listing.add_variant(variant);

    assert!(listing.variants().contains(&vid), 0);
    let v = listing.variant(&vid);
    assert!(v.variant_name() == b"Small".to_string(), 0);
    assert!(v.price() == 500, 0);
    assert!(v.loyalty_price().is_none(), 0);

    destroy(listing);
    scenario.end();
}

#[test]
fun add_multiple_variants() {
    let mut scenario = test_scenario::begin(@0xA);
    let mut listing = listing::new(b"Coffee".to_string(), scenario.ctx());

    let v_s = listing::new_variant(b"S".to_string(), 300, std::option::none(), scenario.ctx());
    let v_m = listing::new_variant(b"M".to_string(), 500, std::option::none(), scenario.ctx());
    let v_l = listing::new_variant(b"L".to_string(), 700, std::option::none(), scenario.ctx());

    let id_s = listing.add_variant(v_s);
    let id_m = listing.add_variant(v_m);
    let id_l = listing.add_variant(v_l);

    assert!(listing.variants().length() == 3, 0);
    assert!(listing.variant(&id_s).price() == 300, 0);
    assert!(listing.variant(&id_m).price() == 500, 0);
    assert!(listing.variant(&id_l).price() == 700, 0);

    destroy(listing);
    scenario.end();
}

#[test]
fun remove_variant_drops_entry() {
    let mut scenario = test_scenario::begin(@0xA);
    let mut listing = listing::new(b"Coffee".to_string(), scenario.ctx());
    let variant = listing::new_variant(
        b"Small".to_string(),
        500,
        std::option::none(),
        scenario.ctx(),
    );
    let vid = listing.add_variant(variant);

    listing.remove_variant(vid);
    assert!(!listing.variants().contains(&vid), 0);
    assert!(listing.variants().is_empty(), 0);

    destroy(listing);
    scenario.end();
}

#[test, expected_failure(abort_code = listing::EVariantNotFound)]
fun remove_unknown_variant_aborts() {
    let mut scenario = test_scenario::begin(@0xA);
    let mut listing = listing::new(b"Coffee".to_string(), scenario.ctx());

    let phantom_id = object::id_from_address(@0xDEADBEEF);
    listing.remove_variant(phantom_id);

    destroy(listing);
    scenario.end();
}

#[test]
fun set_active_toggles() {
    let mut scenario = test_scenario::begin(@0xA);
    let mut listing = listing::new(b"Coffee".to_string(), scenario.ctx());
    assert!(listing.active(), 0);

    listing.set_active(false);
    assert!(!listing.active(), 0);

    listing.set_active(true);
    assert!(listing.active(), 0);

    destroy(listing);
    scenario.end();
}

#[test, expected_failure(abort_code = listing::EActiveStateUnchanged)]
fun set_active_to_same_value_aborts() {
    let mut scenario = test_scenario::begin(@0xA);
    let mut listing = listing::new(b"Coffee".to_string(), scenario.ctx());

    // Listing starts active; setting active=true is a no-op and must abort.
    listing.set_active(true);

    destroy(listing);
    scenario.end();
}

#[test, expected_failure(abort_code = listing::EZeroPrice)]
fun new_variant_zero_price_aborts() {
    let mut scenario = test_scenario::begin(@0xA);
    let v = listing::new_variant(b"Small".to_string(), 0, std::option::none(), scenario.ctx());
    destroy(v);
    scenario.end();
}

#[test, expected_failure(abort_code = listing::EZeroPrice)]
fun new_variant_zero_loyalty_price_aborts() {
    let mut scenario = test_scenario::begin(@0xA);
    let v = listing::new_variant(
        b"Small".to_string(),
        500,
        std::option::some(0),
        scenario.ctx(),
    );
    destroy(v);
    scenario.end();
}