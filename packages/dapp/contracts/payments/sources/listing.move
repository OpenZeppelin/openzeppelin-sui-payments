module openzeppelin_payments::listing;

use std::string::String;

// === Errors ===

#[error(code = 0)]
const EEmptyName: vector<u8> = b"Listing name cannot be empty";
#[error(code = 1)]
const EZeroPrice: vector<u8> = b"Listing price must be greater than zero";

// === Structs ===

// TODO#q: add multiple custom attributes per catalogue item

public struct Listing has drop, store {
    id: ID,
    name: String,
    price_units: u64,
    active: bool,
}

// === View Functions ===

public fun listing_id(self: &Listing): ID { self.id }

public fun listing_name(self: &Listing): &String { &self.name }

public fun listing_price(self: &Listing): u64 { self.price_units }

public fun listing_active(self: &Listing): bool { self.active }

// === Package Functions ===

/// Construct a Listing with a freshly-generated `ID` (via
/// `tx_context::fresh_object_address`). The ID is used both as the Table key on
/// `Merchant.listings` and stored on the listing itself for convenience.
public(package) fun new(name: String, price_units: u64, ctx: &mut TxContext): Listing {
    assert!(!name.is_empty(), EEmptyName);
    assert!(price_units > 0, EZeroPrice);

    let id = object::id_from_address(ctx.fresh_object_address());
    Listing { id, name, price_units, active: true }
}

public(package) fun set_price(self: &mut Listing, price_units: u64) {
    assert!(price_units > 0, EZeroPrice);

    self.price_units = price_units;
}

public(package) fun set_name(self: &mut Listing, name: String) {
    assert!(!name.is_empty(), EEmptyName);
    
    self.name = name;
}

public(package) fun set_active(self: &mut Listing, active: bool) {
    self.active = active;
}
