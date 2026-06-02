/// Listing — merchant menu items and their priced variants.
///
/// A `Listing` represents one menu entry (e.g. "Black Coffee") and holds a map
/// of priced `Variant`s keyed by their auto-generated `ID` (e.g. S/M/L). Each
/// variant carries a stablecoin `price` and an optional `loyalty_price`, allowing
/// customers to pay in either currency. Listings live as values inside
/// `Merchant.listings` — they do not exist independently of their owning Merchant.
module openzeppelin_payments::listing;

use std::string::String;
use sui::vec_map::{Self, VecMap};

// === Errors ===

#[error(code = 0)]
const EEmptyName: vector<u8> = b"Listing name cannot be empty";
#[error(code = 1)]
const EZeroPrice: vector<u8> = b"Listing price must be greater than zero";
#[error(code = 2)]
const EVariantNotFound: vector<u8> = b"Variant not found";
#[error(code = 3)]
const EActiveStateUnchanged: vector<u8> = b"Listing already has the requested active state";

// === Structs ===

/// A menu entry. Holds zero-or-more priced variants and an `active` toggle.
public struct Listing has drop, store {
    id: ID,
    name: String,
    variants: VecMap<ID, Variant>,
    active: bool,
}

/// A priced variant of a Listing (e.g. a size). Identified by its own `id`,
/// which is used as the key in `Listing.variants`.
public struct Variant has drop, store {
    id: ID,
    name: String,
    price: u64,
    loyalty_price: Option<u64>,
}

// === Public Functions ===

/// Construct a Listing with a freshly-generated `ID` (via
/// `tx_context::fresh_object_address`) and no variants. Variants are added
/// post-construction via `add_variant`. The ID is used both as the Table key
/// on `Merchant.listings` and stored on the listing itself for convenience.
public fun new(name: String, ctx: &mut TxContext): Listing {
    assert!(!name.is_empty(), EEmptyName);

    let id = object::id_from_address(ctx.fresh_object_address());
    Listing { id, name, variants: vec_map::empty(), active: true }
}

/// Construct a `Variant` with a freshly-generated `ID` stored inside it (used
/// as the key when inserted into a Listing via `add_variant`). `name` must be
/// non-empty; `price` must be > 0; `loyalty_price`, if Some, must also be > 0.
public fun new_variant(
    name: String,
    price: u64,
    loyalty_price: Option<u64>,
    ctx: &mut TxContext,
): Variant {
    assert!(!name.is_empty(), EEmptyName);
    assert!(price > 0, EZeroPrice);
    if (loyalty_price.is_some()) {
        assert!(*loyalty_price.borrow() > 0, EZeroPrice);
    };

    let id = object::id_from_address(ctx.fresh_object_address());
    Variant { id, name, price, loyalty_price }
}

// === View Functions ===

/// The Listing's stable ID. Matches its key in `Merchant.listings`.
public fun id(self: &Listing): ID { self.id }

/// Display name of the listing (e.g. "Black Coffee").
public fun name(self: &Listing): &String { &self.name }

/// All variants on this listing, keyed by variant ID.
public fun variants(self: &Listing): &VecMap<ID, Variant> { &self.variants }

/// Look up a variant by ID. Aborts if not present.
public fun variant(self: &Listing, variant: &ID): &Variant {
    assert!(self.variants.contains(variant), EVariantNotFound);

    self.variants.get(variant)
}

/// Whether the listing is purchasable.
public fun active(self: &Listing): bool { self.active }

/// Display name of the variant (e.g. "Small").
public fun variant_name(self: &Variant): &String { &self.name }

/// Stablecoin price in token units.
public fun price(self: &Variant): u64 { self.price }

/// Optional price in `LOYALTY` units. `None` if the variant cannot be paid in loyalty.
public fun loyalty_price(self: &Variant): &Option<u64> { &self.loyalty_price }

// === Package Functions ===

/// Insert a variant and return its ID. Aborts if the variant's `id` already
/// exists in this listing.
public(package) fun add_variant(self: &mut Listing, variant: Variant): ID {
    let id = variant.id;
    self.variants.insert(id, variant);
    id
}

/// Remove a variant by ID. Aborts if the variant does not exist.
public(package) fun remove_variant(self: &mut Listing, variant_id: ID) {
    assert!(self.variants.contains(&variant_id), EVariantNotFound);

    let (_, _) = self.variants.remove(&variant_id);
}

/// Rename the listing. `name` must be non-empty.
public(package) fun set_name(self: &mut Listing, name: String) {
    assert!(!name.is_empty(), EEmptyName);

    self.name = name;
}

/// Toggle whether this listing is purchasable. Aborts if `active` matches the
/// current state (no-op guard).
public(package) fun set_active(self: &mut Listing, active: bool) {
    assert!(self.active != active, EActiveStateUnchanged);

    self.active = active;
}
