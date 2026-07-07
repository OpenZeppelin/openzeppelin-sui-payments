/// Tests for `listing.move` — pure data-structure tests for `Listing` and
/// `Variant`. No PAS or Merchant setup needed since `listing::new` is `public`
/// and `add_variant` / `remove_variant` / `set_active` are `public(package)`,
/// callable from package-internal test code.
#[test_only]
module openzeppelin_payments::listing_tests;

use openzeppelin_payments::listing;
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario;

#[test]
fun new_listing_starts_empty_and_active() {
    let mut scenario = test_scenario::begin(@0xA);

    let listing = listing::new(b"Coffee".to_string());
    assert_eq!(*listing.name(), b"Coffee".to_string());
    assert!(listing.active());
    assert!(listing.variants().is_empty());

    destroy(listing);
    scenario.end();
}

#[test, expected_failure(abort_code = listing::EEmptyName)]
fun new_listing_empty_name_aborts() {
    let mut scenario = test_scenario::begin(@0xA);
    let listing = listing::new(b"".to_string());
    destroy(listing);
    scenario.end();
}

#[test]
fun add_variant_inserts_and_returns_id() {
    let mut scenario = test_scenario::begin(@0xA);

    let mut listing = listing::new(b"Coffee".to_string());
    let variant = listing::new_variant(
        b"Small".to_string(),
        500,
        std::option::none(),
    );
    let vid = object::id_from_address(scenario.ctx().fresh_object_address());
    listing.add_variant(variant, vid);

    assert!(listing.variants().contains(&vid));
    let v = listing.variant(&vid);
    assert_eq!(*v.variant_name(), b"Small".to_string());
    assert_eq!(v.price(), 500);
    assert!(v.loyalty_price().is_none());

    destroy(listing);
    scenario.end();
}

#[test]
fun add_multiple_variants() {
    let mut scenario = test_scenario::begin(@0xA);
    let mut listing = listing::new(b"Coffee".to_string());

    let v_s = listing::new_variant(b"S".to_string(), 300, std::option::none());
    let v_m = listing::new_variant(b"M".to_string(), 500, std::option::none());
    let v_l = listing::new_variant(b"L".to_string(), 700, std::option::none());

    let id_s = object::id_from_address(scenario.ctx().fresh_object_address());
    listing.add_variant(v_s, id_s);
    let id_m = object::id_from_address(scenario.ctx().fresh_object_address());
    listing.add_variant(v_m, id_m);
    let id_l = object::id_from_address(scenario.ctx().fresh_object_address());
    listing.add_variant(v_l, id_l);

    assert_eq!(listing.variants().length(), 3);
    assert_eq!(listing.variant(&id_s).price(), 300);
    assert_eq!(listing.variant(&id_m).price(), 500);
    assert_eq!(listing.variant(&id_l).price(), 700);

    destroy(listing);
    scenario.end();
}

#[test]
fun remove_variant_drops_entry() {
    let mut scenario = test_scenario::begin(@0xA);
    let mut listing = listing::new(b"Coffee".to_string());
    let variant = listing::new_variant(
        b"Small".to_string(),
        500,
        std::option::none(),
    );
    let vid = object::id_from_address(scenario.ctx().fresh_object_address());
    listing.add_variant(variant, vid);

    listing.remove_variant(vid);
    assert!(!listing.variants().contains(&vid));
    assert!(listing.variants().is_empty());

    destroy(listing);
    scenario.end();
}

#[test, expected_failure(abort_code = listing::EVariantNotFound)]
fun remove_unknown_variant_aborts() {
    let mut scenario = test_scenario::begin(@0xA);
    let mut listing = listing::new(b"Coffee".to_string());

    let phantom_id = object::id_from_address(@0xDEADBEEF);
    listing.remove_variant(phantom_id);

    destroy(listing);
    scenario.end();
}

#[test]
fun set_active_toggles() {
    let mut scenario = test_scenario::begin(@0xA);
    let mut listing = listing::new(b"Coffee".to_string());
    assert!(listing.active());

    listing.set_active(false);
    assert!(!listing.active());

    listing.set_active(true);
    assert!(listing.active());

    destroy(listing);
    scenario.end();
}

#[test, expected_failure(abort_code = listing::EActiveStateUnchanged)]
fun set_active_to_same_value_aborts() {
    let mut scenario = test_scenario::begin(@0xA);
    let mut listing = listing::new(b"Coffee".to_string());

    // Listing starts active; setting active=true is a no-op and must abort.
    listing.set_active(true);

    destroy(listing);
    scenario.end();
}

#[test, expected_failure(abort_code = listing::EZeroPrice)]
fun new_variant_zero_price_aborts() {
    let mut scenario = test_scenario::begin(@0xA);
    let v = listing::new_variant(b"Small".to_string(), 0, std::option::none());
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
    );
    destroy(v);
    scenario.end();
}

#[test, expected_failure(abort_code = listing::EEmptyName)]
fun new_variant_empty_name_aborts() {
    let mut scenario = test_scenario::begin(@0xA);
    let _ = listing::new_variant(b"".to_string(), 500, std::option::none());
    scenario.end();
}
