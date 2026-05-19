/// Treasury operations for MY_COIN.
///
/// Handles minting (deposit into Account) and burning (clawback from Account),
/// enforcing KYC compliance rules on all operations.
module kyc::treasury;

use kyc::kyc_registry::{Self, KYCRegistry, TransferApproval, ClawbackApproval};
use kyc::my_coin::MY_COIN;
use pas::account::Account;
use pas::clawback_funds::{Self, ClawbackFunds};
use pas::namespace::Namespace;
use pas::policy::{Self, Policy};
use pas::request::Request;
use pas::templates::{PAS, Templates};
use ptb::ptb;
use std::type_name;
use sui::balance::Balance;
use sui::coin::TreasuryCap;

// ==== Setup ====

/// One-time setup: PAS policy + compliance template.
/// Call after publishing (TreasuryCap is created in `my_coin::init`).
#[allow(lint(self_transfer))]
public fun setup(
    namespace: &mut Namespace,
    templates: &mut Templates,
    registry: &KYCRegistry,
    treasury_cap: &mut TreasuryCap<MY_COIN>,
    ctx: &mut TxContext,
) {
    // 1. Create policy with clawback enabled
    let (mut policy, policy_cap) = policy::new_for_currency(
        namespace,
        treasury_cap,
        true, // clawback allowed (for burn)
    );

    // 2. Set required approvals per action
    policy.set_required_approval<_, TransferApproval>(&policy_cap, "send_funds");
    policy.set_required_approval<_, ClawbackApproval>(&policy_cap, "clawback_funds");

    // 3. Register template so the SDK can auto-construct approve_transfer calls
    let type_name = type_name::with_defining_ids<MY_COIN>();

    let cmd = ptb::move_call(
        type_name.address_string().to_string(),
        "kyc_registry",
        "approve_transfer",
        vector[ptb::object_by_id(object::id(registry)), ptb::ext_input<PAS>("request")],
        vector[],
    );

    templates.set_template_command(kyc_registry::transfer_approval_permit(), cmd);

    policy.share();
    transfer::public_transfer(policy_cap, ctx.sender());
}

// ==== Mint & Burn ====

/// Mint tokens and deposit into a user's Account.
public fun mint(
    registry: &KYCRegistry,
    to_account: &Account,
    cap: &mut TreasuryCap<MY_COIN>,
    amount: u64,
) {
    registry.validate_mint(to_account.owner());
    to_account.deposit_balance(cap.mint_balance(amount));
}

/// Burn tokens from a user's Account via clawback.
public fun burn(
    policy: &Policy<Balance<MY_COIN>>,
    cap: &mut TreasuryCap<MY_COIN>,
    mut request: Request<ClawbackFunds<Balance<MY_COIN>>>,
    ctx: &mut TxContext,
) {
    kyc_registry::approve_clawback(&mut request);
    let balance = clawback_funds::resolve(request, policy);
    cap.burn(balance.into_coin(ctx));
}
