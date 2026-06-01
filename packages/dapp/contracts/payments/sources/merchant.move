/// Merchant identity, central state, and listing CRUD. This module is the leaf for
/// the merchant-side flows — it does NOT depend on `invoice` or `redemption`. Those
/// modules import `Merchant` from here and own the issuance + settlement flows for
/// their respective asset sides (invoice → stablecoin payment, redemption →
/// loyalty burn).
///
/// Access control: `AccessControl<MERCHANT>` (from `openzeppelin_access`) is
/// created in `init` as a shared object and seeded with `OperatorRole` granted
/// to the deployer. All admin entry points take `&Auth<OperatorRole>`, which
/// the caller mints from the registry via `access_control::new_auth`. The root
/// role (`MERCHANT` OTW) grants/revokes `OperatorRole` and can be transferred
/// or renounced via the access-control timelock flow.
///
/// Two-step deployment:
///   1. `sui publish` runs both `loyalty::init` (LOYALTY currency) and
///      `merchant::init` (AccessControl<MERCHANT>). The deployer holds:
///      - `TreasuryCap<LOYALTY>` (owned, to be consumed by `loyalty::create`),
///      - root role + `OperatorRole` on the shared `AccessControl<MERCHANT>`.
///   2. Deployer's PTB:
///        loyalty   = loyalty::create(&mut namespace, treasury_cap)
///        config    = config::new(num, den, max, invoice_ttl_ms, voucher_ttl_ms)
///        merchant  = merchant::create(loyalty, config, name, logo_url, payout, ctx)
///        merchant::share(merchant);
module openzeppelin_payments::merchant;

use openzeppelin_access::access_control::{Self, Auth};
use openzeppelin_payments::config::Config;
use openzeppelin_payments::events;
use openzeppelin_payments::listing::{Listing, Variant};
use openzeppelin_payments::loyalty::Loyalty;
use std::string::String;
use sui::table::{Self, Table};

// === Errors ===

#[error(code = 0)]
const EEmptyName: vector<u8> = b"Merchant name cannot be empty";
#[error(code = 1)]
const EListingNotFound: vector<u8> = b"Listing not found";
#[error(code = 2)]
const EVariantNotFound: vector<u8> = b"Variant not found in catalog";
#[error(code = 3)]
const EConfigUnchanged: vector<u8> = b"Config matches the current value";

// === Constants ===

/// Timelock (in ms) applied to root role transfer / renounce on the shared
/// `AccessControl<MERCHANT>`. 24 hours.
const ROOT_TRANSFER_DELAY_MS: u64 = 86_400_000;

// === Init ===

/// One-time witness — struct name == module name uppercased. Consumed once
/// in `init` to mint the package's `AccessControl<MERCHANT>` registry.
public struct MERCHANT has drop {}

/// Role marker — holders can call every cap-gated admin entry point on the
/// `Merchant` shared object. Granted to the deployer in `init`; the root
/// admin can grant/revoke via `access_control::grant_role` / `revoke_role`.
public struct OperatorRole {}

/// Module init — runs once on package publish. Creates the
/// `AccessControl<MERCHANT>` shared registry, grants `OperatorRole` to the
/// deployer (sender), and shares the registry.
fun init(otw: MERCHANT, ctx: &mut TxContext) {
    let mut ac = access_control::new(otw, ROOT_TRANSFER_DELAY_MS, ctx);
    ac.grant_role<_, OperatorRole>(ctx.sender(), ctx);
    transfer::public_share_object(ac);
}

// === Structs ===

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
    /// Loyalty asset bundle (treasury cap, policy cap, policy id). Stored whole;
    /// only accessible via `loyalty()` / `loyalty_mut()`.
    loyalty: Loyalty,
    /// Loyalty mint configuration (numerator/denominator/cap). Replaceable via
    /// `set_config` — note that changing the rate alters "$1 = X points" for
    /// future settlements; existing invoices already snapshot both their
    /// stablecoin `amount` and `loyalty` values at issuance, so they're unaffected.
    config: Config,
    /// Listing CRUD lives below; this is the storage. Keys are freshly-generated
    /// `ID`s (via `tx_context::fresh_object_address`).
    listings: Table<ID, Listing>,
    /// Reverse index: `variant_id -> listing_id`. Lets checkout look up a variant
    /// from a single ID without the customer having to carry both IDs. Maintained
    /// in lockstep with `Listing.variants` by `add_listing`/`remove_listing` and
    /// `add_listing_variant`/`remove_listing_variant`.
    variant_index: Table<ID, ID>,
}

// === Public Functions ===

/// Consume the `Loyalty` bundle from `loyalty::create` and return the
/// `Merchant`. Bootstrap-only — the Loyalty hot-potato is the gating
/// mechanism; subsequent admin operations are gated by `OperatorRole` via
/// `AccessControl<MERCHANT>`. Caller is expected to follow up with
/// `merchant::share(merchant)` in the same PTB.
public fun create(
    loyalty: Loyalty,
    config: Config,
    name: String,
    logo_url: Option<String>,
    payout_address: address,
    ctx: &mut TxContext,
): Merchant {
    assert!(!name.is_empty(), EEmptyName);

    Merchant {
        id: object::new(ctx),
        name,
        logo_url,
        payout_address,
        loyalty,
        config,
        listings: table::new(ctx),
        variant_index: table::new(ctx),
    }
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

/// Reference to the merchant's `Loyalty` bundle (treasury + policy caps + policy id).
public fun loyalty(self: &Merchant): &Loyalty { &self.loyalty }

public fun config(self: &Merchant): &Config { &self.config }

public fun listing(self: &Merchant, id: ID): &Listing {
    assert!(self.listings.contains(id), EListingNotFound);

    self.listings.borrow(id)
}

/// Resolve a listing variant from the catalog by ID, going through `variant_index` to
/// find its parent listing. Aborts with `EVariantNotFound` if the variant is
/// not registered.
public fun listing_variant(self: &Merchant, listing_variant_id: &ID): &Variant {
    assert!(self.variant_index.contains(*listing_variant_id), EVariantNotFound);

    let listing_id = *self.variant_index.borrow(*listing_variant_id);
    self.listings.borrow(listing_id).variant(listing_variant_id)
}

// === Admin Functions ===

public fun set_payout_address(self: &mut Merchant, _auth: &Auth<OperatorRole>, addr: address) {
    self.payout_address = addr;
}

public fun set_display(
    self: &mut Merchant,
    _auth: &Auth<OperatorRole>,
    name: String,
    logo: Option<String>,
) {
    assert!(!name.is_empty(), EEmptyName);
    self.name = name;
    self.logo_url = logo;
}

/// Replace the merchant's loyalty mint `Config`. Build the new value via
/// `config::new(...)` and pass it in. The replacement is effective for
/// subsequent settlements only; invoices already issued keep their snapshot
/// `amount` and `loyalty` values and are unaffected. Aborts with
/// `EConfigUnchanged` if the new config equals the current one.
public fun set_config(self: &mut Merchant, _auth: &Auth<OperatorRole>, config: Config) {
    assert!(&self.config != &config, EConfigUnchanged);

    self.config = config;

    let merchant_id = object::id(self);
    events::emit_config_updated(merchant_id);
}

/// Take ownership of a caller-built `Listing` and store it under its own ID.
/// Every variant already on the listing is registered in `variant_index` so
/// checkout can resolve it from the variant ID alone. Aborts if the listing
/// ID or any of its variant IDs already exist on the merchant.
public fun add_listing(self: &mut Merchant, _auth: &Auth<OperatorRole>, listing: Listing): ID {
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
public fun remove_listing(self: &mut Merchant, _auth: &Auth<OperatorRole>, id: ID) {
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
public fun set_listing_status(
    self: &mut Merchant,
    _auth: &Auth<OperatorRole>,
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
    _auth: &Auth<OperatorRole>,
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

/// Remove a variant by ID from its listing. The owning listing is resolved
/// via `variant_index` — no separate `listing_id` argument needed. Aborts
/// with `EVariantNotFound` if the variant is not registered.
public fun remove_listing_variant(self: &mut Merchant, _auth: &Auth<OperatorRole>, variant_id: ID) {
    assert!(self.variant_index.contains(variant_id), EVariantNotFound);

    let listing_id = self.variant_index.remove(variant_id);
    self.listings.borrow_mut(listing_id).remove_variant(variant_id);

    let merchant_id = object::id(self);
    events::emit_variant_removed(merchant_id, listing_id, variant_id);
}

// === Package Functions ===

/// Mutable reference to the merchant's `Loyalty` bundle. Used by `invoice::pay`
/// (mint earned loyalty) and `redemption::redeem` (burn redeemed loyalty) to
/// reach the treasury cap via `loyalty::treasury_cap_mut`.
public(package) fun loyalty_mut(self: &mut Merchant): &mut Loyalty {
    &mut self.loyalty
}

// === Test-Only Helpers ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(MERCHANT {}, ctx);
}
