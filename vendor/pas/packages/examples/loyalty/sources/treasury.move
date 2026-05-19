/// Treasury operations for LOYALTY_COIN.
///
/// Handles minting (deposit into Account) and redemption (unlock) resolution.
/// Demonstrates that once funds are redeemed (unlocked), they leave the managed
/// system and become unrestricted — the loyalty manager loses control.
module loyalty::treasury;

use loyalty::loyalty_coin::LOYALTY_COIN;
use loyalty::loyalty_manager::{Self, RedeemRegistry, TransferApproval, RedeemApproval};
use pas::account::Account;
use pas::namespace::Namespace;
use pas::policy::{Self, Policy};
use pas::request::Request;
use pas::templates::{PAS, Templates};
use pas::unlock_funds::{Self, UnlockFunds};
use ptb::ptb;
use std::type_name;
use sui::balance::Balance;
use sui::coin::TreasuryCap;

// ==== Setup ====

/// One-time setup: PAS policy + approval templates.
/// Call after publishing (TreasuryCap is created in `loyalty_coin::init`).
#[allow(lint(self_transfer))]
public fun setup(
    namespace: &mut Namespace,
    templates: &mut Templates,
    treasury_cap: &mut TreasuryCap<LOYALTY_COIN>,
    ctx: &mut TxContext,
) {
    // 1. Create policy — clawback disabled (not the focus of this example)
    let (mut policy, policy_cap) = policy::new_for_currency(
        namespace,
        treasury_cap,
        false,
    );

    // 2. Set required approvals per action
    policy.set_required_approval<_, TransferApproval>(&policy_cap, "send_funds");
    policy.set_required_approval<_, RedeemApproval>(&policy_cap, "unlock_funds");

    // 3. Register template commands so the SDK can auto-construct approval calls
    let type_name = type_name::with_defining_ids<LOYALTY_COIN>();

    // Template for transfer approval (permissionless — no cap needed)
    let transfer_cmd = ptb::move_call(
        type_name.address_string().to_string(),
        "loyalty_manager",
        "approve_transfer",
        vector[ptb::ext_input<PAS>("request")],
        vector[],
    );
    templates.set_template_command(loyalty_manager::transfer_approval_permit(), transfer_cmd);

    policy.share();
    transfer::public_transfer(policy_cap, ctx.sender());
}

// ==== Mint & Redeem ====

/// Mint loyalty points and deposit into a user's Account.
public fun mint(cap: &mut TreasuryCap<LOYALTY_COIN>, to_account: &Account, amount: u64) {
    to_account.deposit_balance(cap.mint_balance(amount));
}

/// Approve and resolve a redemption (unlock) request.
///
/// CAUTION: After this function returns, the resulting Coin<LOYALTY_COIN>
/// is a regular, unrestricted coin. It can be:
///   - Transferred to ANY address (no manager approval needed)
///   - Split, merged, or used in DeFi protocols
///   - Sent to addresses that would otherwise fail compliance checks
///
/// Issuers should carefully consider whether enabling `unlock_funds`
/// is appropriate for their token's compliance requirements.
#[allow(lint(self_transfer))]
public fun redeem(
    registry: &RedeemRegistry,
    policy: &Policy<Balance<LOYALTY_COIN>>,
    mut request: Request<UnlockFunds<Balance<LOYALTY_COIN>>>,
    ctx: &mut TxContext,
) {
    // Check eligibility and approve the redemption
    loyalty_manager::approve_redeem(registry, &mut request);

    // Resolve against policy — returns raw Balance<LOYALTY_COIN>
    let balance = unlock_funds::resolve(request, policy);

    // The balance is now completely outside the managed system.
    // Sending as balance to the sender's address — no further restrictions apply.
    balance.send_funds(ctx.sender());
}
