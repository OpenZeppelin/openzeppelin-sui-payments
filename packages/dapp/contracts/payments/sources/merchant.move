/// Merchant identity, central state, bootstrap, listing CRUD, and payment.
///
/// Two-step deployment:
///   1. `sui publish` → `loyalty::init` creates the LOYALTY currency. Deployer holds
///      `TreasuryCap<LOYALTY>` and a frozen `CoinMetadata<LOYALTY>`.
///   2. Deployer's PTB:
///        loyalty         = loyalty::setup(&mut namespace, treasury_cap, ctx)
///        (merchant, cap) = merchant::create(loyalty, name, logo_url, payout,
///                                           num, den, max, ctx)
///        merchant::share(merchant);  transfer `cap` to the deployer's address.
///
/// Cap-by-reference gating: every merchant-only entry (here and in `redemption`) takes
/// `&MerchantCap`. `assert_cap_matches` verifies the cap's `merchant_id` field equals
/// `object::id(&Merchant)`.
module openzeppelin_payments::merchant;

use openzeppelin_payments::events;
use openzeppelin_payments::listing::{Self, Listing};
use openzeppelin_payments::loyalty::{Self, Loyalty, LOYALTY};
use pas::account::Account;
use pas::policy::PolicyCap;
use std::string::String;
use sui::balance::Balance;
use sui::clock::Clock;
use sui::coin::{Coin, TreasuryCap};
use sui::table::{Self, Table};

// === Errors ===

#[error(code = 0)]
const EWrongMerchantCap: vector<u8> = b"MerchantCap does not match this Merchant";
#[error(code = 1)]
const EEmptyName: vector<u8> = b"Merchant name cannot be empty";
#[error(code = 2)]
const EZeroMintDenominator: vector<u8> = b"Mint denominator cannot be zero";
#[error(code = 3)]
const EListingNotFound: vector<u8> = b"Listing not found";
#[error(code = 4)]
const EWrongLoyaltyRecipient: vector<u8> = b"Loyalty account owner does not match payer";

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
    /// Listing CRUD lives below; this is the storage.
    listings: Table<u64, Listing>,
    /// Monotonic, never reused even on remove — keeps off-chain references (QR codes,
    /// historical indexer entries) stable.
    next_listing_id: u64,
}

/// Owned capability. `key, store` so it can be transferred between addresses.
public struct MerchantCap has key, store {
    id: UID,
    merchant_id: ID,
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
        next_listing_id: 0,
    };
    let merchant_id = object::id(&merchant);

    let cap = MerchantCap {
        id: object::new(ctx),
        merchant_id,
    };

    (merchant, cap)
}

/// Share the `Merchant`. Required because `Merchant` is `key`-only (no `store`), so
/// `transfer::share_object` can only be called from this module — an external caller
/// can't share it directly. Call after `create` and any same-PTB setup.
public fun share(m: Merchant) {
    transfer::share_object(m);
}

/// Atomic payment: route `Coin<S>` to `merchant.payout_address`, mint loyalty into the
/// customer's `Account<LOYALTY>`, emit `events::PaymentEvent`. Generic over the
/// stablecoin Coin type `S`. Stablecoin transfer is a plain Sui transfer (no PAS) —
/// see the design note in `04-code.md`. Loyalty mint goes through PAS via
/// `loyalty::mint_into`.
public fun pay<S>(
    m: &mut Merchant,
    coin: Coin<S>,
    customer_loyalty_account: &Account,
    order_ref: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let merchant_id = object::id(m);
    let payout = m.payout_address;
    let num = m.mint_numerator;
    let den = m.mint_denominator;
    let max = m.max_mint_per_payment;

    let customer_addr = ctx.sender();
    let payment_amount = coin.value();

    // INV: loyalty mints to the payer's own loyalty account.
    assert!(customer_loyalty_account.owner() == customer_addr, EWrongLoyaltyRecipient);

    // Route the stablecoin to the merchant. Plain Sui transfer.
    transfer::public_transfer(coin, payout);

    // u128 intermediate to dodge overflow when payment_amount * num exceeds u64.
    let raw: u128 = (payment_amount as u128) * (num as u128) / (den as u128);
    let mint_amount: u64 = if (raw > (max as u128)) { max } else { (raw as u64) };

    if (mint_amount > 0) {
        loyalty::mint_into(&mut m.loyalty_treasury_cap, customer_loyalty_account, mint_amount);
    };

    events::emit_payment(
        merchant_id,
        order_ref,
        customer_addr,
        payment_amount,
        mint_amount,
        clock.timestamp_ms(),
    );
}

// === View Functions ===

public fun name(m: &Merchant): &String { &m.name }

public fun logo_url(m: &Merchant): &Option<String> { &m.logo_url }

public fun payout_address(m: &Merchant): address { m.payout_address }

public fun loyalty_policy_id(m: &Merchant): ID { m.loyalty_policy_id }

public fun mint_params(m: &Merchant): (u64, u64, u64) {
    (m.mint_numerator, m.mint_denominator, m.max_mint_per_payment)
}

public fun next_listing_id(m: &Merchant): u64 { m.next_listing_id }

public fun listings_count(m: &Merchant): u64 { m.listings.length() }

public fun merchant_id(cap: &MerchantCap): ID { cap.merchant_id }

public fun borrow_listing(m: &Merchant, id: u64): &Listing {
    assert!(m.listings.contains(id), EListingNotFound);
    m.listings.borrow(id)
}

public fun contains_listing(m: &Merchant, id: u64): bool {
    m.listings.contains(id)
}

/// Verify the cap matches this Merchant. Called by every merchant-only entry (here
/// and in `redemption`).
public fun assert_cap_matches(m: &Merchant, cap: &MerchantCap) {
    assert!(object::id(m) == cap.merchant_id, EWrongMerchantCap);
}

// === Admin Functions ===

public fun set_payout_address(m: &mut Merchant, cap: &MerchantCap, addr: address) {
    assert_cap_matches(m, cap);
    m.payout_address = addr;
}

public fun set_display(m: &mut Merchant, cap: &MerchantCap, name: String, logo: Option<String>) {
    assert_cap_matches(m, cap);
    assert!(!name.is_empty(), EEmptyName);
    m.name = name;
    m.logo_url = logo;
}

public fun add_listing(m: &mut Merchant, cap: &MerchantCap, name: String, price_units: u64): u64 {
    assert_cap_matches(m, cap);
    let id = m.next_listing_id;
    m.next_listing_id = m.next_listing_id + 1;
    let listing = listing::new(id, name, price_units);
    m.listings.add(id, listing);
    id
}

public fun set_listing_price(m: &mut Merchant, cap: &MerchantCap, id: u64, price_units: u64) {
    assert_cap_matches(m, cap);
    assert!(m.listings.contains(id), EListingNotFound);
    listing::set_price(m.listings.borrow_mut(id), price_units);
}

public fun set_listing_name(m: &mut Merchant, cap: &MerchantCap, id: u64, name: String) {
    assert_cap_matches(m, cap);
    assert!(m.listings.contains(id), EListingNotFound);
    listing::set_name(m.listings.borrow_mut(id), name);
}

public fun set_listing_active(m: &mut Merchant, cap: &MerchantCap, id: u64, active: bool) {
    assert_cap_matches(m, cap);
    assert!(m.listings.contains(id), EListingNotFound);
    listing::set_active(m.listings.borrow_mut(id), active);
}

public fun remove_listing(m: &mut Merchant, cap: &MerchantCap, id: u64): Listing {
    assert_cap_matches(m, cap);
    assert!(m.listings.contains(id), EListingNotFound);
    m.listings.remove(id)
}

// === Package Functions ===

/// Borrow the loyalty TreasuryCap for `redemption::verify` (burn). `pay` mints via the
/// field directly since it already holds `&mut Merchant`.
public(package) fun loyalty_treasury_cap_mut(m: &mut Merchant): &mut TreasuryCap<LOYALTY> {
    &mut m.loyalty_treasury_cap
}
