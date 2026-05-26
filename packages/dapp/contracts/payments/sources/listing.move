module openzeppelin_payments::listing;

use std::string::String;

// === Errors ===

#[error(code = 0)]
const EEmptyName: vector<u8> = b"Listing name cannot be empty";
#[error(code = 1)]
const EZeroPrice: vector<u8> = b"Listing price must be greater than zero";

// === Structs ===

public struct Listing has drop, store {
    id: u64,
    name: String,
    price_units: u64,
    active: bool,
}

// === View Functions ===

public fun listing_id(l: &Listing): u64 { l.id }

public fun listing_name(l: &Listing): &String { &l.name }

public fun listing_price(l: &Listing): u64 { l.price_units }

public fun listing_active(l: &Listing): bool { l.active }

// === Package Functions ===

public(package) fun new(id: u64, name: String, price_units: u64): Listing {
    assert!(!name.is_empty(), EEmptyName);
    assert!(price_units > 0, EZeroPrice);
    Listing { id, name, price_units, active: true }
}

public(package) fun set_price(l: &mut Listing, price_units: u64) {
    assert!(price_units > 0, EZeroPrice);
    l.price_units = price_units;
}

public(package) fun set_name(l: &mut Listing, name: String) {
    assert!(!name.is_empty(), EEmptyName);
    l.name = name;
}

public(package) fun set_active(l: &mut Listing, active: bool) {
    l.active = active;
}
