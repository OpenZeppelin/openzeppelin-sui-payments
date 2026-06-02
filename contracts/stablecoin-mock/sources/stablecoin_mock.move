/// Mock PAS-managed stablecoin for dev/testnet. The customer holds `Balance<STABLECOIN_MOCK>`
/// in their PAS `Account` and transfers it via PAS `send_funds`. Production deployments
/// instantiate `payment::pay<S>` with a real PAS-issued stablecoin; this mock just lets
/// the template's payment flow be exercised end-to-end without an external issuer.
///
/// Two-step deployment (parallels `loyalty.move`):
///   1. Publish → `init` creates the Sui currency + metadata, transfers `TreasuryCap` to
///      the deployer.
///   2. Deployer calls `setup(&mut namespace, &mut treasury_cap, ctx)` to create
///      `Policy<Balance<STABLECOIN_MOCK>>` and register the permissive `TransferApproval`
///      witness for `send_funds`. PolicyCap transferred to the deployer.
///
/// Customer's payment PTB calls `stablecoin_mock::approve_transfer(&mut sf_request)` to
/// stamp the approval witness on a `Request<SendFunds<Balance<STABLECOIN_MOCK>>>` before
/// passing it to `payment::pay`.
module local_mock_stablecoin::stablecoin_mock;

use pas::account::Account;
use pas::namespace::Namespace;
use pas::policy;
use pas::request::Request;
use pas::send_funds::SendFunds;
use sui::balance::Balance;
use sui::coin::TreasuryCap;
use sui::coin_registry;

// === Init ===

/// One-time witness.
public struct STABLECOIN_MOCK has drop {}

fun init(otw: STABLECOIN_MOCK, ctx: &mut TxContext) {
    let (initializer, cap) = coin_registry::new_currency_with_otw(
        otw,
        6,
        b"MOCKUSD".to_string(),
        b"Mock USD".to_string(),
        b"Mock PAS-managed stablecoin for OpenZeppelin Sui Payments template (devnet only).".to_string(),
        b"".to_string(),
        ctx,
    );
    let metadata = initializer.finalize(ctx);
    transfer::public_freeze_object(metadata);
    transfer::public_transfer(cap, ctx.sender());
}

// === Structs ===

/// Permissive transfer approval witness. Anyone can produce one — the mock allows
/// free transfers (devnet only). A real PAS stablecoin would gate this on KYC,
/// allowlist, etc.
public struct TransferApproval() has drop;

// === Public Functions ===

/// Post-publish setup: create the PAS `Policy<Balance<STABLECOIN_MOCK>>`, register the
/// permissive `TransferApproval` for `send_funds`, share the policy, and transfer the
/// `PolicyCap` to the deployer.
#[allow(lint(self_transfer))]
public fun setup(
    namespace: &mut Namespace,
    treasury_cap: &mut TreasuryCap<STABLECOIN_MOCK>,
    ctx: &mut TxContext,
) {
    let (mut policy, policy_cap) = policy::new_for_currency(namespace, treasury_cap, false);
    policy.set_required_approval<_, TransferApproval>(
        &policy_cap,
        b"send_funds".to_string(),
    );
    policy::share(policy);
    transfer::public_transfer(policy_cap, ctx.sender());
}

/// Permissionless faucet — mints `amount` mock USD into the recipient's PAS Account.
/// Devnet only.
public fun faucet(
    cap: &mut TreasuryCap<STABLECOIN_MOCK>,
    recipient_account: &Account,
    amount: u64,
) {
    recipient_account.deposit_balance(cap.mint_balance(amount));
}

/// Permissive transfer approval — stamps the `TransferApproval` witness on a pending
/// `send_funds` request so the customer's `Policy<Balance<STABLECOIN_MOCK>>` will
/// resolve it. Called by the customer's PTB before `payment::pay`.
public fun approve_transfer(request: &mut Request<SendFunds<Balance<STABLECOIN_MOCK>>>) {
    request.approve(TransferApproval());
}
