/// Redemption flow — extracts loyalty balance from the customer's PAS Account into a
/// `Redemption` shared object, then either:
///   - merchant `verify`s it → balance is burned, OR
///   - `release` is called (permissionless) after expiry → balance returns to customer.
///
/// Authorization model: `verify` is gated solely by `&MerchantCap`. The merchant is
/// trusted to only verify redemptions whose customers have presented themselves at
/// the counter. There is no on-chain proof of customer presence — disputes are
/// handled off-chain. An earlier design used a sha3-256 code commitment, but it
/// provided no real protection for human-friendly short codes (a 6–9 digit input is
/// trivially brute-forced from the on-chain hash), so it was dropped in favor of the
/// simpler honest trust model.
///
/// Lifecycle (customer's PTB):
///   auth       = account::new_auth(&ctx)
///   request    = customer_loyalty_account.unlock_balance<LOYALTY>(&auth, amount, &ctx)
///   redemption = redemption::create(merchant, request, policy_loyalty, ttl_ms, &clock, ctx)
///   redemption::share(redemption)
module openzeppelin_payments::redemption;

use openzeppelin_payments::events;
use openzeppelin_payments::loyalty::{Self, LOYALTY};
use openzeppelin_payments::merchant::{Merchant, MerchantCap};
use pas::account::Account;
use pas::policy::Policy;
use pas::request::Request;
use pas::unlock_funds::{Self, UnlockFunds};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin;

// TODO#q: have to flows with Redemption verification: Merchant only + User 

// === Errors ===

#[error(code = 0)]
const EZeroTtl: vector<u8> = b"ttl_ms must be greater than zero";
#[error(code = 1)]
const EZeroAmount: vector<u8> = b"Redemption amount must be greater than zero";
#[error(code = 2)]
const EWrongMerchantForRedemption: vector<u8> =
    b"Redemption was not created for this Merchant";
#[error(code = 3)]
const EExpired: vector<u8> = b"Redemption has expired";
#[error(code = 4)]
const ENotExpired: vector<u8> = b"Redemption has not yet expired";
#[error(code = 5)]
const EWrongCustomer: vector<u8> = b"Account owner does not match Redemption customer";

// === Structs ===

public struct Redemption has key {
    id: UID,
    merchant_id: ID,
    customer: address,
    funds: Balance<LOYALTY>,
    expires_at_ms: u64,
}

// === Public Functions ===

/// Customer initiates redemption. Approves the unlock with our package-private
/// witness, resolves it via the loyalty `Policy<Balance<LOYALTY>>`, and stashes the
/// resulting balance in a fresh `Redemption`. The caller shares it via
/// `redemption::share` (the object is `key`-only, so `share_object` is restricted to
/// this module).
public fun create(
    merchant: &Merchant,
    mut request: Request<UnlockFunds<Balance<LOYALTY>>>,
    policy_loyalty: &Policy<Balance<LOYALTY>>,
    ttl_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Redemption {
    assert!(ttl_ms > 0, EZeroTtl);

    let merchant_id = object::id(merchant);
    let customer = request.data().owner();
    let amount = request.data().funds().value();
    assert!(amount > 0, EZeroAmount);

    request.approve(loyalty::new_redeem_unlock_approval());
    let funds: Balance<LOYALTY> = unlock_funds::resolve(request, policy_loyalty);

    let redemption = Redemption {
        id: object::new(ctx),
        merchant_id,
        customer,
        funds,
        expires_at_ms: clock.timestamp_ms() + ttl_ms,
    };

    events::emit_redemption_created(
        object::id(&redemption),
        merchant_id,
        customer,
        amount,
        redemption.expires_at_ms,
    );
    redemption
}

/// Share the `Redemption`. Required because it is `key`-only (no `store`), so
/// `transfer::share_object` can only be called from this module. Call after `create`.
public fun share(redemption: Redemption) {
    transfer::share_object(redemption);
}

/// Permissionless release after expiry — returns the held balance to the customer's
/// loyalty Account. Prevents griefing by an inactive merchant.
public fun release(
    redemption: Redemption,
    customer_loyalty_account: &Account,
    clock: &Clock,
) {
    let redemption_id = object::id(&redemption);
    let now = clock.timestamp_ms();

    assert!(now >= redemption.expires_at_ms, ENotExpired);
    assert!(customer_loyalty_account.owner() == redemption.customer, EWrongCustomer);

    let Redemption { id, merchant_id, customer, funds, .. } = redemption;
    let amount = funds.value();
    customer_loyalty_account.deposit_balance(funds);
    id.delete();

    events::emit_redemption_released(redemption_id, merchant_id, customer, amount);
}

// === Admin Functions ===

/// Merchant verifies the redemption and burns the held balance. Consumes the Redemption.
/// Gated solely by `&MerchantCap` — the merchant is trusted to only call this for
/// customers who have actually presented themselves.
public fun verify(
    merchant: &mut Merchant,
    cap: &MerchantCap,
    redemption: Redemption,
    clock: &Clock,
) {
    merchant.assert_cap_matches(cap);

    let merchant_id_now = object::id(merchant);
    let redemption_id = object::id(&redemption);
    let now = clock.timestamp_ms();

    assert!(redemption.merchant_id == merchant_id_now, EWrongMerchantForRedemption);
    assert!(now < redemption.expires_at_ms, EExpired);

    let Redemption { id, merchant_id, customer, funds, .. } = redemption;
    let amount = funds.value();
    balance::decrease_supply(
        coin::supply_mut(merchant.loyalty_treasury_cap_mut()),
        funds,
    );
    id.delete();

    events::emit_redemption_verified(redemption_id, merchant_id, customer, amount);
}
