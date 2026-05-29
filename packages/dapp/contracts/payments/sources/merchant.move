/// Merchant identity, central state, and listing CRUD. This module is the leaf for
/// the merchant-side flows — it does NOT depend on `invoice` or `redemption`. Those
/// modules import `Merchant`/`MerchantCap` from here and own the issuance + settlement
/// flows for their respective asset sides (invoice → stablecoin payment, redemption →
/// loyalty burn).
///
/// Two-step deployment:
///   1. `sui publish` → `loyalty::init` creates the LOYALTY currency. Deployer holds
///      `TreasuryCap<LOYALTY>` and a frozen `CoinMetadata<LOYALTY>`.
///   2. Deployer's PTB:
///        loyalty         = loyalty::create(&mut namespace, treasury_cap, ctx)
///        (merchant, cap) = merchant::create(loyalty, name, logo_url, payout,
///                                           num, den, max, ctx)
///        merchant::share(merchant);  transfer `cap` to the deployer's address.
///
/// Cap-by-reference gating: every merchant-only entry takes `__cap: &MerchantCap`.
/// The package's OTW + Loyalty-hot-potato bootstrap guarantees exactly one
/// `MerchantCap` exists per published package, so possession alone is the access
/// control — no merchant-binding field or cap-id assert needed.
module openzeppelin_payments::merchant;

use openzeppelin_payments::events;
use openzeppelin_payments::listing::{Listing, Variant};
use openzeppelin_payments::loyalty::{Self, Loyalty, LOYALTY};
use pas::policy::PolicyCap;
use std::string::String;
use sui::balance::Balance;
use sui::coin::TreasuryCap;
use sui::table::{Self, Table};

// === Errors ===

#[error(code = 0)]
const EEmptyName: vector<u8> = b"Merchant name cannot be empty";
#[error(code = 1)]
const EZeroMintDenominator: vector<u8> = b"Mint denominator cannot be zero";
#[error(code = 2)]
const EListingNotFound: vector<u8> = b"Listing not found";
#[error(code = 3)]
const EZeroQuantity: vector<u8> = b"Item quantity must be greater than zero";
#[error(code = 4)]
const EVariantNotFound: vector<u8> = b"Variant not found in catalog";
#[error(code = 5)]
const EAmountOverflow: vector<u8> = b"Amount exceeds u64 range";

// === Structs ===

// TODO#q: group loyalty like structs together
// TODO#q: mint_* move to configuration object

/// Central shared object holding the merchant's entire on-chain state.
public struct Merchant has key {
    id: UID,
    /// Display name (e.g. "Joe's Coffee"). Mutable via `set_display`.
    name: String,
    /// Optional logo URL.
    logo_url: Option<String>,
    /// Address receiving customer stablecoin payments. Mutable so the merchant can
    /// rotate keys.
    payout_address: address,
    /// Loyalty asset bundle, set at `create`, immutable thereafter.
    loyalty_treasury_cap: TreasuryCap<LOYALTY>,
    loyalty_policy_cap: PolicyCap<Balance<LOYALTY>>,
    loyalty_policy_id: ID,
    /// Mint rate: `loyalty_minted = (payment_units * num) / den`, capped at `max`.
    /// All three set at `create`, immutable thereafter — runtime mutation
    /// would change "$1 = X points" under existing customers.
    mint_numerator: u64,
    mint_denominator: u64,
    max_mint_per_payment: u64,
    /// Listing CRUD lives below; this is the storage. Keys are freshly-generated
    /// `ID`s (via `tx_context::fresh_object_address`).
    listings: Table<ID, Listing>,
    /// Reverse index: `variant_id -> listing_id`. Lets checkout look up a variant
    /// from a single ID without the customer having to carry both IDs. Maintained
    /// in lockstep with `Listing.variants` by `add_listing`/`remove_listing` and
    /// `add_listing_variant`/`remove_listing_variant`.
    variant_index: Table<ID, ID>,
}

// TODO#q: create capabilities for catalog CRUD, redemption verifications and balance withdrawal.

/// Owned capability. `key, store` so it can be transferred between addresses. The
/// package's OTW + Loyalty-hot-potato bootstrap guarantees exactly one `MerchantCap`
/// exists per published package, so possession alone is the access control — no
/// merchant-binding field needed.
public struct MerchantCap has key, store {
    id: UID,
}

/// One line on an `Invoice` (or a `Voucher`) — a quantity of a specific listing
/// variant at a snapshotted unit price. The price is in stablecoin units for
/// invoices and `LOYALTY` units for vouchers; the type is the same so it can be
/// reused across both flows. Snapshot pricing decouples the order from later
/// mutations of the underlying `Variant`.
public struct Item has copy, drop, store {
    variant_id: ID,
    quantity: u64,
    unit_price: u64,
}

// === Public Functions ===

/// Consume the `Loyalty` bundle from `loyalty::setup` and return the `Merchant` and its
/// `MerchantCap`. The caller controls placement — typically `merchant::share(merchant)`
/// (and any same-PTB setup like `add_listing`) then transfers the cap to the deployer.
public fun create(
    loyalty: Loyalty,
    name: String,
    logo_url: Option<String>,
    payout_address: address,
    mint_numerator: u64,
    mint_denominator: u64,
    max_mint_per_payment: u64,
    ctx: &mut TxContext,
): (Merchant, MerchantCap) {
    assert!(!name.is_empty(), EEmptyName);
    assert!(mint_denominator != 0, EZeroMintDenominator);

    let (treasury_cap, policy_cap, policy_id) = loyalty::destruct(loyalty);

    let merchant = Merchant {
        id: object::new(ctx),
        name,
        logo_url,
        payout_address,
        loyalty_treasury_cap: treasury_cap,
        loyalty_policy_cap: policy_cap,
        loyalty_policy_id: policy_id,
        mint_numerator,
        mint_denominator,
        max_mint_per_payment,
        listings: table::new(ctx),
        variant_index: table::new(ctx),
    };
    let cap = MerchantCap { id: object::new(ctx) };

    (merchant, cap)
}

/// Share the `Merchant`. Required because `Merchant` is `key`-only (no `store`), so
/// `transfer::share_object` can only be called from this module — an external caller
/// can't share it directly. Call after `create` and any same-PTB setup.
public fun share(m: Merchant) {
    transfer::share_object(m);
}

// === View Functions ===

public fun name(self: &Merchant): &String { &self.name }

public fun logo_url(self: &Merchant): &Option<String> { &self.logo_url }

public fun payout_address(self: &Merchant): address { self.payout_address }

public fun loyalty_policy_id(self: &Merchant): ID { self.loyalty_policy_id }

public fun mint_params(self: &Merchant): (u64, u64, u64) {
    (self.mint_numerator, self.mint_denominator, self.max_mint_per_payment)
}

public fun listing(self: &Merchant, id: ID): &Listing {
    assert!(self.listings.contains(id), EListingNotFound);

    self.listings.borrow(id)
}

public fun variant_id(self: &Item): ID { self.variant_id }

public fun quantity(self: &Item): u64 { self.quantity }

public fun unit_price(self: &Item): u64 { self.unit_price }

// === Admin Functions ===

public fun set_payout_address(self: &mut Merchant, _cap: &MerchantCap, addr: address) {
    self.payout_address = addr;
}

public fun set_display(
    self: &mut Merchant,
    _cap: &MerchantCap,
    name: String,
    logo: Option<String>,
) {
    assert!(!name.is_empty(), EEmptyName);
    self.name = name;
    self.logo_url = logo;
}

/// Take ownership of a caller-built `Listing` and store it under its own ID.
/// Every variant already on the listing is registered in `variant_index` so
/// checkout can resolve it from the variant ID alone. Aborts if the listing
/// ID or any of its variant IDs already exist on the merchant.
public fun add_listing(self: &mut Merchant, _cap: &MerchantCap, listing: Listing): ID {
    let id = listing.id();
    let merchant_id = object::id(self);

    listing.variants().keys().do!(|vid| {
        self.variant_index.add(vid, id);
    });

    self.listings.add(id, listing);
    events::emit_listing_added(merchant_id, id);

    id
}

/// Pull a `Listing` out of the merchant. Every variant on the removed listing
/// is also dropped from `variant_index`.
public fun remove_listing(self: &mut Merchant, _cap: &MerchantCap, id: ID) {
    assert!(self.listings.contains(id), EListingNotFound);

    let merchant_id = object::id(self);
    let removed = self.listings.remove(id);

    removed.variants().keys().do!(|vid| {
        let _: ID = self.variant_index.remove(vid);
    });

    events::emit_listing_removed(merchant_id, id);
}

/// Toggle a listing's `active` flag. Aborts if the listing does not exist, or
/// if `active` already matches the listing's current state (no-op guard from
/// `listing::set_active`).
public fun set_listing_activity(
    self: &mut Merchant,
    _cap: &MerchantCap,
    listing_id: ID,
    active: bool,
) {
    assert!(self.listings.contains(listing_id), EListingNotFound);

    let merchant_id = object::id(self);
    self.listings.borrow_mut(listing_id).set_active(active);

    events::emit_listing_status_changed(merchant_id, listing_id, active);
}

/// Insert a variant into an existing listing and return its ID. The new variant
/// is also registered in `variant_index`. Aborts if the listing does not exist
/// or if the variant's `id` already exists.
public fun add_listing_variant(
    self: &mut Merchant,
    _cap: &MerchantCap,
    listing_id: ID,
    variant: Variant,
): ID {
    assert!(self.listings.contains(listing_id), EListingNotFound);

    let merchant_id = object::id(self);
    let id = self.listings.borrow_mut(listing_id).add_variant(variant);
    self.variant_index.add(id, listing_id);

    events::emit_variant_added(merchant_id, listing_id, id);

    id
}

/// Remove a variant by ID from an existing listing. Also dropped from
/// `variant_index`. Aborts if the listing or the variant does not exist.
public fun remove_listing_variant(
    self: &mut Merchant,
    _cap: &MerchantCap,
    listing_id: ID,
    variant_id: ID,
) {
    assert!(self.listings.contains(listing_id), EListingNotFound);

    let merchant_id = object::id(self);
    self.listings.borrow_mut(listing_id).remove_variant(variant_id);
    let _: ID = self.variant_index.remove(variant_id);

    events::emit_variant_removed(merchant_id, listing_id, variant_id);
}

// === Package Functions ===

/// Borrow the loyalty TreasuryCap. Called by `invoice::pay` (mint earned loyalty)
/// and `redemption::redeem` (burn redeemed loyalty).
public(package) fun loyalty_treasury_cap_mut(m: &mut Merchant): &mut TreasuryCap<LOYALTY> {
    &mut m.loyalty_treasury_cap
}

/// Build an order line by snapshotting the variant's current stablecoin price.
/// The listing is resolved from `variant_index` so callers only need the
/// variant ID. `quantity` must be > 0. Aborts if the variant is not registered.
public(package) fun new_item(merchant: &Merchant, variant_id: ID, quantity: u64): Item {
    assert!(quantity > 0, EZeroQuantity);
    assert!(merchant.variant_index.contains(variant_id), EVariantNotFound);

    let listing_id = *merchant.variant_index.borrow(variant_id);
    let unit_price = merchant.listing(listing_id).variant(&variant_id).price();

    Item { variant_id, quantity, unit_price }
}


// TODO#q: make public and move to the receipt.move module (can be reused by customer to calculate balance)

/// Sum `item.quantity * item.unit_price` across all items using a u128 accumulator,
/// asserting the final total fits in u64 (otherwise aborts with `EAmountOverflow`).
public(package) fun compute_total(items: &vector<Item>): u64 {
    let mut total: u128 = 0;
    items.do_ref!(|item| {
        total = total + (item.quantity() as u128) * (item.unit_price() as u128);
    });

    total.try_as_u64().destroy_or!(abort EAmountOverflow)
}
