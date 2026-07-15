/// WARNING — LOCALNET/TESTNET ONLY. Do NOT publish this package to mainnet, and never set a
/// production `Merchant`'s `accepted_payment_type` to `STABLECOIN_MOCK`. The supply is freely
/// mintable (`faucet` / `faucet_coin`) and transfers are freely approvable (the permissive
/// `TransferApproval`), so settling a real invoice in this currency would be worthless.
/// Production deployments instantiate `payment::pay<C>` with a real PAS-issued stablecoin.
///
/// Mock PAS-managed stablecoin for dev/testnet. The customer holds `Balance<STABLECOIN_MOCK>`
/// in their PAS `Account` and transfers it via PAS `send_funds`. This mock just lets the
/// template's payment flow be exercised end-to-end without an external issuer.
///
/// Two-step deployment (parallels `loyalty.move`):
///   1. Publish → `init` registers the Sui currency and transfers the `TreasuryCap` and
///      `MetadataCap` to the deployer (the `MetadataCap` is owned, NOT frozen — see `init`).
///   2. Deployer calls `setup(&mut namespace, &mut treasury_cap, &mut templates, ctx)` to
///      create `Policy<Balance<STABLECOIN_MOCK>>`, register the permissive `TransferApproval`
///      witness for `send_funds`, and register a PTB template (in the shared PAS
///      `Templates` registry) for auto-resolving it. PolicyCap transferred to the deployer.
///
/// Customer's payment PTB calls `stablecoin_mock::approve_transfer(&mut sf_request)` to
/// stamp the approval witness on a `Request<SendFunds<Balance<STABLECOIN_MOCK>>>` before
/// passing it to `payment::pay`. A PAS-aware wallet can instead read the registered PTB
/// template and insert that call automatically.
module local_mock_stablecoin::stablecoin_mock;

use pas::account::Account;
use pas::namespace::Namespace;
use pas::policy;
use pas::request::Request;
use pas::send_funds::SendFunds;
use pas::templates::{PAS, Templates};
use ptb::ptb;
use std::type_name;
use sui::balance::Balance;
use sui::coin::{Self, Coin, TreasuryCap};
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
        b"Mock PAS-managed stablecoin for OpenZeppelin Sui Payments template (localnet/testnet only).".to_string(),
        b"".to_string(),
        ctx,
    );

    let metadata_cap = initializer.finalize(ctx);
    transfer::public_transfer(metadata_cap, ctx.sender());
    transfer::public_transfer(cap, ctx.sender());
}

// === Structs ===

/// Permissive transfer approval witness. Anyone can produce one — the mock allows
/// free transfers (localnet/testnet only). A real PAS stablecoin would gate this on KYC,
/// allowlist, etc.
public struct TransferApproval() has drop;

// === Public Functions ===

/// Post-publish setup: create the PAS `Policy<Balance<STABLECOIN_MOCK>>`, register the
/// permissive `TransferApproval` for `send_funds`, register the PTB template that lets
/// wallets auto-resolve that approval, share the policy, and transfer the `PolicyCap`
/// to the deployer.
///
/// `templates` is the shared PAS `Templates` registry (from `pas::templates::setup`).
#[allow(lint(self_transfer))]
public fun setup(
    namespace: &mut Namespace,
    treasury_cap: &mut TreasuryCap<STABLECOIN_MOCK>,
    templates: &mut Templates,
    ctx: &mut TxContext,
) {
    let (mut policy, policy_cap) = policy::new_for_currency(namespace, treasury_cap, false);
    policy.set_required_approval<_, TransferApproval>(
        &policy_cap,
        b"send_funds".to_string(),
    );
    policy::share(policy);
    transfer::public_transfer(policy_cap, ctx.sender());

    // Register the PTB template for `TransferApproval` so a PAS-aware wallet can
    // auto-resolve the `send_funds` approval: to satisfy it, call
    // `stablecoin_mock::approve_transfer(request)`, where `request` is the
    // send-funds request being resolved (injected by the off-chain resolver).
    let transfer_cmd = ptb::move_call(
        type_name::with_defining_ids<TransferApproval>().address_string().to_string(),
        b"stablecoin_mock".to_string(),
        b"approve_transfer".to_string(),
        vector[ptb::ext_input<PAS>(b"request".to_string())],
        vector[],
    );
    templates.set_template_command(internal::permit<TransferApproval>(), transfer_cmd);
}

/// Deployer-only faucet — mints `amount` mock USD into the recipient's PAS
/// Account. Requires the holder of `TreasuryCap<STABLECOIN_MOCK>` (owned by
/// the deployer after `init`) to call; not a permissionless tap. For a real
/// permissionless faucet, wrap the cap inside a shared object with rate-limiting.
/// Localnet/testnet only.
public fun faucet(
    cap: &mut TreasuryCap<STABLECOIN_MOCK>,
    recipient_account: &Account,
    amount: u64,
) {
    recipient_account.deposit_balance(cap.mint_balance(amount));
}

/// Deployer-only coin faucet — mints `amount` mock USD as a plain, owned
/// `Coin<STABLECOIN_MOCK>` and returns it. This is the open-loop counterpart to
/// `faucet`: the coin is meant to be spent directly via `merchant::pay_with_coin`
/// (or `public_transfer`-ed to a customer), not held in a PAS Account. Requires
/// the holder of `TreasuryCap<STABLECOIN_MOCK>` (owned by the deployer after
/// `init`) to call; not a permissionless tap. For a real permissionless faucet,
/// wrap the cap inside a shared object with rate-limiting. Localnet/testnet only.
public fun faucet_coin(
    cap: &mut TreasuryCap<STABLECOIN_MOCK>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<STABLECOIN_MOCK> {
    coin::mint(cap, amount, ctx)
}

/// Permissive transfer approval — stamps the `TransferApproval` witness on a pending
/// `send_funds` request so the customer's `Policy<Balance<STABLECOIN_MOCK>>` will
/// resolve it. Called by the customer's PTB before `payment::pay`.
public fun approve_transfer(request: &mut Request<SendFunds<Balance<STABLECOIN_MOCK>>>) {
    request.approve(TransferApproval());
}
