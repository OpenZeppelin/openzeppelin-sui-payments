/// `LOYALTY` currency + the `Loyalty` bundle that hands its caps to the
/// `Merchant`. The OTW pattern guarantees exactly one `TreasuryCap<LOYALTY>`
/// ever exists; that cap is consumed by `create` into the hot-potato `Loyalty`
/// bundle, which `merchant::create` consumes into the shared `Merchant`. After
/// bootstrap, no path can mint a second cap or stand up a second merchant.
///
/// LOYALTY is soulbound: the policy registers `RedeemUnlockApproval` for
/// `unlock_funds` (so redemption can take balance out of a customer's account)
/// but does NOT register an approval for `send_funds`. Account-to-account
/// transfers can never resolve.
module openzeppelin_payments::loyalty;

use pas::account::Account;
use pas::namespace::Namespace;
use pas::policy::{Self, PolicyCap};
use sui::balance::Balance;
use sui::coin::TreasuryCap;
use sui::coin_registry;

// === Init ===

/// One-time witness — struct name == module name, uppercased.
public struct LOYALTY has drop {}

/// Module init — creates the standard Sui currency and freezes its metadata.
/// Policy creation happens in `create` (the second deployer tx) because
/// `policy::new_for_currency` requires `&mut Namespace` which `init` can't take.
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
    let metadata = initializer.finalize(ctx);
    transfer::public_freeze_object(metadata);
    transfer::public_transfer(cap, ctx.sender());
}

// === Structs ===

/// Bundle of loyalty-side outputs from `create`, consumed by `merchant::create`
/// which moves it whole into `Merchant.loyalty`. `store`-only — no `drop` and
/// no `copy`, so the value is a hot potato that must be stored inside another
/// struct (the Merchant) before the transaction ends. No `key`, so it cannot
/// exist as a top-level on-chain object.
public struct Loyalty has store {
    treasury_cap: TreasuryCap<LOYALTY>,
    policy_cap: PolicyCap<Balance<LOYALTY>>,
    policy_id: ID,
}

/// Approval witness consumed when `redemption` resolves an `unlock_funds` request.
/// `drop` so adding it to a `Request` (`request.approve(w)`) consumes cleanly.
/// Constructor is package-private — only modules in this package can produce one.
public struct RedeemUnlockApproval() has drop;

// === Public Functions ===

/// Post-publish setup. Creates `Policy<Balance<LOYALTY>>` against the global PAS
/// Namespace, registers approvals, shares the policy, and bundles the loyalty-side
/// outputs into a `Loyalty` to be consumed by `merchant::create` in the same PTB.
///
/// Approval registration:
///   - `unlock_funds`    requires `RedeemUnlockApproval` (gates redemption)
///   - `send_funds`      NOT registered → soulbound (transfers can never resolve)
///   - `clawback_funds`  NOT registered + `clawback_allowed = false`
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

/// Reference to the underlying `TreasuryCap<LOYALTY>`.
public fun treasury_cap(self: &Loyalty): &TreasuryCap<LOYALTY> { &self.treasury_cap }

/// Reference to the underlying `PolicyCap<Balance<LOYALTY>>`.
public fun policy_cap(self: &Loyalty): &PolicyCap<Balance<LOYALTY>> { &self.policy_cap }

/// ID of the shared `Policy<Balance<LOYALTY>>` created in `create`.
public fun policy_id(self: &Loyalty): ID { self.policy_id }

// === Package Functions ===

/// Mutable accessor for the treasury cap. Used by `payment::pay` (mint) and
/// `redemption::redeem` (burn) via `merchant::loyalty_mut`.
public(package) fun treasury_cap_mut(self: &mut Loyalty): &mut TreasuryCap<LOYALTY> {
    &mut self.treasury_cap
}

/// Mint into the customer's PAS Account. Called by `payment::pay`.
/// `deposit_balance` is unrestricted in PAS (no `Auth` needed), so the customer
/// doesn't have to sign for the loyalty-side leg — only for their stablecoin spend.
public(package) fun mint_into(
    cap: &mut TreasuryCap<LOYALTY>,
    customer_account: &Account,
    amount: u64,
) {
    customer_account.deposit_balance(cap.mint_balance(amount));
}

/// Witness factory. Only `redemption::create` calls this.
public(package) fun new_redeem_unlock_approval(): RedeemUnlockApproval {
    RedeemUnlockApproval()
}
