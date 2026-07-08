/// `LOYALTY` currency + the `Loyalty` bundle that hands its caps to the
/// `Merchant`. The OTW pattern guarantees exactly one `TreasuryCap<LOYALTY>`
/// ever exists; that cap is consumed by `create` into the `Loyalty` linear
/// resource bundle, which `merchant::create` consumes into the shared
/// `Merchant`. After bootstrap, no path can mint a second cap or stand up a
/// second merchant.
///
/// LOYALTY is soulbound: the policy registers `RedeemUnlockApproval` for
/// `unlock_funds` (so redemption can take balance out of a customer's account)
/// but does NOT register an approval for `send_funds`. Account-to-account
/// transfers can never resolve.
module openzeppelin_payments::loyalty;

use pas::account::Account;
use pas::namespace::Namespace;
use pas::policy::{Self, PolicyCap};
use sui::balance::{Self, Balance};
use sui::coin::{Self, TreasuryCap};
use sui::coin_registry;

// === Structs ===

/// One-time witness - struct name == module name, uppercased.
public struct LOYALTY has drop {}

/// Bundle of loyalty-side outputs from `create`, consumed by `merchant::create`
/// which moves it whole into `Merchant.loyalty`. `store`-only - no `drop` and
/// no `copy`, so the value is a linear resource that must be moved into
/// another struct (the Merchant) before the transaction ends. No `key`, so it
/// cannot exist as a top-level on-chain object.
public struct Loyalty has store {
    /// Mint/burn authority for `LOYALTY`. Mutably accessed only through the
    /// package-private `mint_to` / `decrease_supply` methods on `Loyalty`
    /// itself - the field, the cap, and `&mut TreasuryCap` are never reachable
    /// outside this module.
    treasury_cap: TreasuryCap<LOYALTY>,
    /// PAS authority over `Policy<Balance<LOYALTY>>`. Held but never exposed
    /// mutably - the policy is locked once registered in `create`.
    policy_cap: PolicyCap<Balance<LOYALTY>>,
    /// ID of the shared `Policy<Balance<LOYALTY>>` created in `create`. Useful
    /// for off-chain consumers that need to resolve the policy object.
    policy_id: ID,
}

/// Approval witness consumed when `redemption` resolves an `unlock_funds` request.
/// `drop` so adding it to a `Request` (`request.approve(w)`) consumes cleanly.
/// Constructor is package-private - only modules in this package can produce one.
public struct RedeemUnlockApproval() has drop;

// === Init ===

/// Module init - registers the standard Sui currency and hands the deployer its
/// `TreasuryCap` and `MetadataCap`.
///
/// Policy creation happens in `create` (the second deployer tx) because
/// `policy::new_for_currency` requires `&mut Namespace`, which `init` cannot
/// take.
///
/// The `MetadataCap` is transferred to the deployer (owned), NOT frozen. Freezing
/// it would be unsafe: `coin_registry::set_name`/`set_description`/`set_icon_url`
/// take the cap by *immutable* reference, so a frozen (publicly readable) cap
/// would let anyone rewrite the shared `Currency<LOYALTY>` metadata. Keeping it
/// owned means only the deployer can update metadata; to make metadata permanently
/// immutable, the deployer can later `coin_registry::delete_metadata_cap` once it
/// holds a `&mut Currency<LOYALTY>` (post `finalize_registration`).
///
/// #### Parameters
/// - `otw`: The `LOYALTY` one-time witness, consumed to register the currency.
/// - `ctx`: Transaction context.
fun init(otw: LOYALTY, ctx: &mut TxContext) {
    let (initializer, cap) = coin_registry::new_currency_with_otw(
        otw,
        0,
        b"LOY".to_string(),
        b"Loyalty Points".to_string(),
        b"OpenZeppelin Sui Payments loyalty token (soulbound).".to_string(),
        b"".to_string(),
        ctx,
    );
    let metadata_cap = initializer.finalize(ctx);
    transfer::public_transfer(metadata_cap, ctx.sender());
    transfer::public_transfer(cap, ctx.sender());
}

// === Public Functions ===

/// Post-publish setup. Creates `Policy<Balance<LOYALTY>>` against the global PAS
/// Namespace, registers approvals, shares the policy, and bundles the loyalty-side
/// outputs into a `Loyalty` to be consumed by `merchant::create` in the same PTB.
///
/// Approval registration:
///   - `unlock_funds`    requires `RedeemUnlockApproval` (gates redemption)
///   - `send_funds`      NOT registered -> soulbound (transfers can never resolve)
///   - `clawback_funds`  NOT registered + `clawback_allowed = false`
///
/// #### Parameters
/// - `namespace`: The global PAS `Namespace` the policy is registered against.
/// - `treasury_cap`: The sole `TreasuryCap<LOYALTY>` from `init`, moved into the bundle.
///
/// #### Returns
/// - The `Loyalty` bundle (treasury cap, policy cap, policy id) for `merchant::create`.
///
/// #### Aborts
/// - Propagates from `policy::new_for_currency` if a `Policy<Balance<LOYALTY>>`
///   already exists for the namespace (e.g. if `create` is called a second time),
///   or if the PAS `Namespace` version check fails.
public fun create(namespace: &mut Namespace, mut treasury_cap: TreasuryCap<LOYALTY>): Loyalty {
    let (mut policy, policy_cap) = policy::new_for_currency(namespace, &mut treasury_cap, false);

    policy.set_required_approval<_, RedeemUnlockApproval>(
        &policy_cap,
        b"unlock_funds".to_string(),
    );

    let policy_id = object::id(&policy);
    policy::share(policy);

    Loyalty { treasury_cap, policy_cap, policy_id }
}

// === View Functions ===

/// ID of the embedded `TreasuryCap<LOYALTY>` - exposed for off-chain
/// indexing only. The cap itself is never borrowed publicly: leaking
/// `&TreasuryCap` would let outsiders read mint metadata they don't need.
public fun treasury_cap_id(self: &Loyalty): ID { object::id(&self.treasury_cap) }

/// ID of the embedded `PolicyCap<Balance<LOYALTY>>` - exposed for off-chain
/// indexing only. The cap itself is NEVER borrowed publicly because PAS
/// uses `&PolicyCap` as authorization: leaking it lets any caller mutate
/// the shared `Policy<Balance<LOYALTY>>` (re-key approvals, break
/// soulbound semantics, brick redemption).
public fun policy_cap_id(self: &Loyalty): ID { object::id(&self.policy_cap) }

/// ID of the shared `Policy<Balance<LOYALTY>>` created in `create`.
public fun policy_id(self: &Loyalty): ID { self.policy_id }

/// Total `LOYALTY` supply currently minted (mints minus burns). Reads
/// through the cap by `&` so it can't be used to authorize mint/burn.
public fun supply(self: &Loyalty): u64 {
    coin::total_supply(&self.treasury_cap)
}

// === Package Functions ===

/// Mint LOYALTY into a customer's PAS Account. Called by `merchant::pay`
/// and `merchant::pay_with_coin`. Borrows the TreasuryCap mutably through
/// `&mut Loyalty` rather than handing it out, so the cap never escapes
/// this module.
///
/// `deposit_balance` is unrestricted in PAS (no `Auth` needed), so the
/// customer doesn't have to sign for the loyalty-side leg - only for their
/// stablecoin spend.
///
/// #### Parameters
/// - `self`: The merchant's `Loyalty` bundle, mutated to mint from.
/// - `customer_account`: The payer's PAS account to deposit the minted balance into.
/// - `amount`: LOYALTY units to mint.
///
/// #### Aborts
/// - Propagates from `mint_balance` if minting `amount` would overflow the
///   `LOYALTY` total supply.
/// - Propagates from `deposit_balance` if `customer_account`'s PAS version check fails.
public(package) fun mint_to(self: &mut Loyalty, customer_account: &Account, amount: u64) {
    customer_account.deposit_balance(self.treasury_cap.mint_balance(amount));
}

/// Burn a `Balance<LOYALTY>` against the embedded TreasuryCap, decreasing
/// total supply. Called by `merchant::redeem` to permanently destroy the
/// LOY locked inside a voucher.
///
/// #### Parameters
/// - `self`: The merchant's `Loyalty` bundle, mutated to burn through.
/// - `funds`: The balance to burn; consumed by value.
public(package) fun decrease_supply(self: &mut Loyalty, funds: Balance<LOYALTY>) {
    balance::decrease_supply(coin::supply_mut(&mut self.treasury_cap), funds);
}

/// Witness factory. Only `redemption::create` calls this.
public(package) fun new_redeem_unlock_approval(): RedeemUnlockApproval {
    RedeemUnlockApproval()
}
