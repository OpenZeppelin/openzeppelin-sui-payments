/// Listing data type. One menu line: `(id, name, price_units, active)`.
///
/// Stored as `Table<u64, Listing>` entries on `Merchant`. CRUD lives in `merchant`
/// (where the table is) — this module exposes only the struct, a package-private
/// constructor / setters used by `merchant`, and public accessors used by readers.
///
/// Modeled after `openzeppelin-sui-marketplace::oracle-market::listing` — one
/// listing per purchasable line. Variant-bearing products (e.g. Latte S/M/L) become
/// three separate listings.
module openzeppelin_payments::listing;

use std::string::String;

#[error(code = 0)]
const EEmptyName: vector<u8> = b"Listing name cannot be empty";
#[error(code = 1)]
const EZeroPrice: vector<u8> = b"Listing price must be greater than zero";

public struct Listing has store, drop {
    id: u64,
    name: String,
    price_units: u64,
    active: bool,
}

// === Package-private constructor + setters (only `merchant` calls these) ===

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

// === Public accessors ===

public fun listing_id(l: &Listing): u64 { l.id }
public fun listing_name(l: &Listing): &String { &l.name }
public fun listing_price(l: &Listing): u64 { l.price_units }
public fun listing_active(l: &Listing): bool { l.active }
