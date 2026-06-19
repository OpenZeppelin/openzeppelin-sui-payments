/// Listing - merchant menu items and their priced variants.
///
/// A `Listing` represents one menu entry (e.g. "Black Coffee") and holds a map
/// of priced `Variant`s keyed by their auto-generated `ID` (e.g. S/M/L). Each
/// variant carries a stablecoin `price` and an optional `loyalty_price`, allowing
/// customers to pay in either currency. Listings live as values inside
/// `Merchant.listings` - they do not exist independently of their owning Merchant.
module openzeppelin_payments::listing;

use std::string::String;
use sui::vec_map::{Self, VecMap};

// === Errors ===

#[error(code = 0)]
const EEmptyName: vector<u8> = "Name cannot be empty";
#[error(code = 1)]
const EZeroPrice: vector<u8> = "Price must be greater than zero";
#[error(code = 2)]
const EVariantNotFound: vector<u8> = "Listing variant not found";
#[error(code = 3)]
const EActiveStateUnchanged: vector<u8> = "Listing already has the requested active state";

// === Structs ===

/// A menu entry. Holds zero-or-more priced variants and an `active` toggle.
public struct Listing has drop, store {
    /// Stable, freshly-generated ID. Also used as the key in `Merchant.listings`.
    id: ID,
    /// Display name (e.g. "Black Coffee").
    name: String,
    /// Priced variants, keyed by `Variant.id`.
    variants: VecMap<ID, Variant>,
    /// Whether this listing is currently purchasable (display hint).
    active: bool,
}

/// A priced variant of a Listing (e.g. a size). Identified by its own `id`,
/// which is used as the key in `Listing.variants`.
public struct Variant has drop, store {
    /// Stable, freshly-generated ID. Used as the key in `Listing.variants` and
    /// in `Merchant.variant_index`.
    id: ID,
    /// Display name (e.g. "Small").
    name: String,
    /// Stablecoin price in token units.
    price: u64,
    /// Optional LOYALTY price. `None` means this variant cannot be paid for in
    /// LOYALTY (voucher creation aborts with `receipt::ENoLoyaltyPrice`).
    loyalty_price: Option<u64>,
}

// === Public Functions ===

/// Construct a Listing with a freshly-generated `ID` and no variants.
///
/// The ID (from `tx_context::fresh_object_address`) is used both as the `Table`
/// key on `Merchant.listings` and stored on the listing itself for convenience.
/// Variants are added post-construction via `add_variant`.
///
/// #### Parameters
/// - `name`: Display name (e.g. "Black Coffee"). Must be non-empty.
/// - `ctx`: Transaction context.
///
/// #### Returns
/// - The constructed `Listing`, marked `active`.
///
/// #### Aborts
/// - `EEmptyName` if `name` is empty.
public fun new(name: String, ctx: &mut TxContext): Listing {
    assert!(!name.is_empty(), EEmptyName);

    let id = object::id_from_address(ctx.fresh_object_address());
    Listing { id, name, variants: vec_map::empty(), active: true }
}

/// Construct a `Variant` with a freshly-generated `ID` stored inside it (used
/// as the key when inserted into a Listing via `add_variant`).
///
/// #### Parameters
/// - `name`: Display name (e.g. "Small"). Must be non-empty.
/// - `price`: Stablecoin price in token units. Must be > 0.
/// - `loyalty_price`: Optional LOYALTY price. If `Some`, must be > 0; `None`
///   means the variant cannot be redeemed for loyalty.
/// - `ctx`: Transaction context.
///
/// #### Returns
/// - The constructed `Variant`.
///
/// #### Aborts
/// - `EEmptyName` if `name` is empty.
/// - `EZeroPrice` if `price` is zero, or if `loyalty_price` is `Some(0)`.
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

/// Look up a variant by ID.
///
/// #### Parameters
/// - `self`: The listing to read.
/// - `variant`: ID of the variant to look up.
///
/// #### Returns
/// - Reference to the matching `Variant`.
///
/// #### Aborts
/// - `EVariantNotFound` if no variant with `variant` exists on this listing.
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
public fun loyalty_price(self: &Variant): Option<u64> { self.loyalty_price }

// === Package Functions ===

/// Insert a variant and return its ID.
///
/// #### Parameters
/// - `self`: The listing to mutate.
/// - `variant`: The variant to insert.
///
/// #### Returns
/// - The inserted variant's ID.
///
/// #### Aborts
/// - Aborts (via `vec_map::insert`) if the variant's `id` already exists in
///   this listing.
public(package) fun add_variant(self: &mut Listing, variant: Variant): ID {
    let id = variant.id;
    self.variants.insert(id, variant);
    id
}

/// Remove a variant by ID.
///
/// #### Parameters
/// - `self`: The listing to mutate.
/// - `variant_id`: ID of the variant to remove.
///
/// #### Aborts
/// - `EVariantNotFound` if no variant with `variant_id` exists on this listing.
public(package) fun remove_variant(self: &mut Listing, variant_id: ID) {
    assert!(self.variants.contains(&variant_id), EVariantNotFound);

    let (_, _) = self.variants.remove(&variant_id);
}

/// Toggle whether this listing is purchasable.
///
/// #### Parameters
/// - `self`: The listing to mutate.
/// - `active`: The new active state.
///
/// #### Aborts
/// - `EActiveStateUnchanged` if `active` already matches the current state.
public(package) fun set_active(self: &mut Listing, active: bool) {
    assert!(self.active != active, EActiveStateUnchanged);

    self.active = active;
}
