/// Soulbound loyalty asset — a standard Sui Coin wrapped with a PAS
/// `Policy<Balance<LOYALTY>>` that registers approvals only for `unlock_funds`.
/// `send_funds` and `clawback_funds` have no approvals registered, so requests for
/// them can never resolve → soulbound, no clawback.
///
/// Two-step deployment:
///   1. Publish → `init` creates the currency + metadata, transfers `TreasuryCap` to
///      the deployer. The Policy is NOT created here because `init` can't take
///      `&mut Namespace` (init's signature is fixed).
///   2. Deployer's second tx is a PTB:
///        loyalty = loyalty::setup(&mut namespace, treasury_cap, ctx)
///        cap     = merchant::create_merchant(loyalty, name, ..., ctx)
///
/// Cross-module hooks (`public(package)`):
///   - `destruct(Loyalty) -> (TreasuryCap, PolicyCap, policy_id)` — consumed by
///     `merchant::create_merchant`.
///   - `mint_into(&mut TreasuryCap, &Account, amount)` — called by `payment::pay`.
///   - `new_redeem_unlock_approval() -> RedeemUnlockApproval` — called by
///     `redemption::request_redeem` to approve the unlock request.
module openzeppelin_payments::loyalty;

use pas::namespace::Namespace;
use pas::policy::{Self, PolicyCap};
use pas::account::Account;
use sui::balance::Balance;
use sui::coin::TreasuryCap;
use sui::coin_registry;

/// One-time witness — struct name == module name, uppercased.
public struct LOYALTY has drop {}

/// Bundle of loyalty-side outputs from `setup`, consumed by
/// `merchant::create_merchant`. `key`-only — has neither `drop` nor `store`,
/// so the deployer cannot accidentally drop it or wrap it elsewhere.
public struct Loyalty has key {
    id: UID,
    treasury_cap: TreasuryCap<LOYALTY>,
    policy_cap: PolicyCap<Balance<LOYALTY>>,
    policy_id: ID,
}

/// Approval witness consumed when `redemption` resolves an `unlock_funds` request.
/// `drop` so adding it to a `Request` (`request.approve(w)`) consumes cleanly.
/// Constructor is package-private — only modules in this package can produce one.
public struct RedeemUnlockApproval() has drop;

/// Module init — creates the standard Sui currency and freezes its metadata.
/// Policy creation happens in `setup` (the second deployer tx) because
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

/// Post-publish setup. Creates `Policy<Balance<LOYALTY>>` against the global PAS
/// Namespace, registers approvals, shares the policy, and bundles the loyalty-side
/// outputs into a `Loyalty` to be consumed by `merchant::create_merchant` in the
/// same PTB.
///
/// Approval registration:
///   - `unlock_funds`    requires `RedeemUnlockApproval` (gates redemption)
///   - `send_funds`      NOT registered → soulbound (transfers can never resolve)
///   - `clawback_funds`  NOT registered + `clawback_allowed = false`
public fun setup(
    namespace: &mut Namespace,
    treasury_cap: TreasuryCap<LOYALTY>,
    ctx: &mut TxContext,
): Loyalty {
    let mut cap = treasury_cap;
    let (mut policy, policy_cap) = policy::new_for_currency(namespace, &mut cap, false);

    policy.set_required_approval<_, RedeemUnlockApproval>(
        &policy_cap,
        b"unlock_funds".to_string(),
    );

    let policy_id = object::id(&policy);
    policy::share(policy);

    Loyalty {
        id: object::new(ctx),
        treasury_cap: cap,
        policy_cap,
        policy_id,
    }
}

// === Package-private hooks ===

/// Unwrap a Loyalty bundle. Only `merchant::create_merchant` calls this.
public(package) fun destruct(
    loyalty: Loyalty,
): (TreasuryCap<LOYALTY>, PolicyCap<Balance<LOYALTY>>, ID) {
    let Loyalty { id, treasury_cap, policy_cap, policy_id } = loyalty;
    id.delete();
    (treasury_cap, policy_cap, policy_id)
}

/// Mint into the customer's PAS Account. Called by `payment::pay`. `deposit_balance`
/// is unrestricted in PAS (no Auth needed), so the customer doesn't have to sign for
/// the loyalty-side leg — only for their stablecoin spend.
public(package) fun mint_into(
    cap: &mut TreasuryCap<LOYALTY>,
    customer_account: &Account,
    amount: u64,
) {
    customer_account.deposit_balance(cap.mint_balance(amount));
}

/// Witness factory. Only `redemption::request_redeem` calls this.
public(package) fun new_redeem_unlock_approval(): RedeemUnlockApproval {
    RedeemUnlockApproval()
}
