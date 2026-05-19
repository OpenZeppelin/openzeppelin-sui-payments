/// Loyalty manager: gates transfers and redemptions (unlocks).
///
/// Transfers between accounts are freely allowed.
/// Redemptions (unlocks) are gated per-address — the manager marks which
/// addresses are eligible to redeem their points.
///
/// IMPORTANT: once a redemption is approved and resolved, the resulting
/// Balance / Coin is completely unrestricted. The manager has no further
/// control over those funds.
module loyalty::loyalty_manager;

use loyalty::loyalty_coin::LOYALTY_COIN;
use pas::request::Request;
use pas::send_funds::SendFunds;
use pas::unlock_funds::UnlockFunds;
use sui::balance::Balance;
use sui::vec_set::{Self, VecSet};

// ==== Error Codes ====

#[error(code = 0)]
const ENotRedeemable: vector<u8> = b"Address is not eligible for redemption";

// ==== Structs ====

/// Witness stamp for approved transfers.
public struct TransferApproval() has drop;

/// Witness stamp for approved redemptions (unlocks).
public struct RedeemApproval() has drop;

/// Admin capability for managing the loyalty program.
public struct ManagerCap has key, store { id: UID }

/// Shared registry of addresses eligible to redeem (unlock) their points.
public struct RedeemRegistry has key {
    id: UID,
    redeemable: VecSet<address>,
}

fun init(ctx: &mut TxContext) {
    transfer::transfer(ManagerCap { id: object::new(ctx) }, ctx.sender());
    transfer::share_object(RedeemRegistry {
        id: object::new(ctx),
        redeemable: vec_set::empty(),
    });
}

// ==== Public ====

/// Approve an account-to-account transfer. Transfers are freely allowed —
/// points stay within the managed system regardless of who receives them.
public fun approve_transfer(request: &mut Request<SendFunds<Balance<LOYALTY_COIN>>>) {
    request.approve(TransferApproval());
}

/// Approve a redemption (unlock) request if the owner is eligible.
///
/// WARNING: after the unlock resolves, the resulting Balance<LOYALTY_COIN> is
/// unrestricted — it can be sent to any address
/// without any further restrictions.
public(package) fun approve_redeem(
    registry: &RedeemRegistry,
    request: &mut Request<UnlockFunds<Balance<LOYALTY_COIN>>>,
) {
    assert!(registry.redeemable.contains(&request.data().owner()), ENotRedeemable);
    request.approve(RedeemApproval());
}

/// Mark an address as eligible for redemption.
public fun allow_redeem(registry: &mut RedeemRegistry, _cap: &ManagerCap, user: address) {
    registry.redeemable.insert(user);
}

/// Revoke redemption eligibility for an address.
public fun disallow_redeem(registry: &mut RedeemRegistry, _cap: &ManagerCap, user: address) {
    registry.redeemable.remove(&user);
}

// ==== Package ====

/// Permit for registering the TransferApproval template command.
public(package) fun transfer_approval_permit(): internal::Permit<TransferApproval> {
    internal::permit()
}
