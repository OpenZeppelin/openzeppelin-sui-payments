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

use openzeppelin_payments::listing::{Self, Listing};
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
    /// `ID`s (via `tx_context::fresh_object_address`) — stable across all listings
    /// past and future, with no monotonic counter to maintain.
    listings: Table<ID, Listing>,
}

// TODO#q: create capabilities for catalog CRUD, redemption verifications and balance withdrawal.

/// Owned capability. `key, store` so it can be transferred between addresses. The
/// package's OTW + Loyalty-hot-potato bootstrap guarantees exactly one `MerchantCap`
/// exists per published package, so possession alone is the access control — no
/// merchant-binding field needed.
public struct MerchantCap has key, store {
    id: UID,
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

// === Admin Functions ===

public fun set_payout_address(self: &mut Merchant, _cap: &MerchantCap, addr: address) {
    self.payout_address = addr;
}

public fun set_display(self: &mut Merchant, _cap: &MerchantCap, name: String, logo: Option<String>) {
    assert!(!name.is_empty(), EEmptyName);
    self.name = name;
    self.logo_url = logo;
}

// TODO#q: can we pass Listing object as an argument?
public fun add_listing(
    self: &mut Merchant,
    _cap: &MerchantCap,
    name: String,
    price_units: u64,
    ctx: &mut TxContext,
): ID {
    let listing = listing::new(name, price_units, ctx);
    let id = listing.listing_id();
    self.listings.add(id, listing);
    id
}

public fun set_listing_price(self: &mut Merchant, _cap: &MerchantCap, id: ID, price_units: u64) {
    assert!(self.listings.contains(id), EListingNotFound);
    listing::set_price(self.listings.borrow_mut(id), price_units);
}

public fun set_listing_name(self: &mut Merchant, _cap: &MerchantCap, id: ID, name: String) {
    assert!(self.listings.contains(id), EListingNotFound);
    listing::set_name(self.listings.borrow_mut(id), name);
}

public fun set_listing_active(self: &mut Merchant, _cap: &MerchantCap, id: ID, active: bool) {
    assert!(self.listings.contains(id), EListingNotFound);
    listing::set_active(self.listings.borrow_mut(id), active);
}

public fun remove_listing(self: &mut Merchant, _cap: &MerchantCap, id: ID): Listing {
    assert!(self.listings.contains(id), EListingNotFound);
    self.listings.remove(id)
}

// === Package Functions ===

/// Borrow the loyalty TreasuryCap. Called by `invoice::pay` (mint earned loyalty)
/// and `redemption::redeem` (burn redeemed loyalty).
public(package) fun loyalty_treasury_cap_mut(m: &mut Merchant): &mut TreasuryCap<LOYALTY> {
    &mut m.loyalty_treasury_cap
}
