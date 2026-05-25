/// Redemption flow — extracts loyalty balance from the customer's PAS Account into a
/// `Redemption` shared object, then either:
///   - merchant `verify`s the preimage to the stored hash → balance is burned, OR
///   - `release` is called (permissionless) after expiry → balance returns to customer.
///
/// Lifecycle (customer's PTB):
///   auth       = account::new_auth(&ctx)
///   request    = customer_loyalty_account.unlock_balance<LOYALTY>(&auth, amount, &ctx)
///   redemption = redemption::create(merchant, request, policy_loyalty,
///                                   code_hash, ttl_ms, &clock, ctx)
///   redemption::share(redemption)
///
/// Code commit-reveal: `code_hash = sha3_256(code)`. The customer sees the raw `code`
/// and shows it at the counter; the merchant types it into the POS, which submits the
/// preimage to `verify`. Move re-hashes and compares.
module openzeppelin_payments::redemption;

use openzeppelin_payments::events;
use openzeppelin_payments::loyalty::{Self, LOYALTY};
use openzeppelin_payments::merchant::{Merchant, MerchantCap};
use pas::account::Account;
use pas::policy::Policy;
use pas::request::Request;
use pas::unlock_funds::{Self, UnlockFunds};
use std::hash;
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin;

// === Errors ===

#[error(code = 0)]
const EEmptyCodeHash: vector<u8> = b"code_hash must be non-empty";
#[error(code = 1)]
const EZeroTtl: vector<u8> = b"ttl_ms must be greater than zero";
#[error(code = 2)]
const EZeroAmount: vector<u8> = b"Redemption amount must be greater than zero";
#[error(code = 3)]
const EWrongMerchantForRedemption: vector<u8> =
    b"Redemption was not created for this Merchant";
#[error(code = 4)]
const EExpired: vector<u8> = b"Redemption has expired";
#[error(code = 5)]
const ENotExpired: vector<u8> = b"Redemption has not yet expired";
#[error(code = 6)]
const EWrongCode: vector<u8> = b"Code does not match commitment";
#[error(code = 7)]
const EWrongCustomer: vector<u8> = b"Account owner does not match Redemption customer";

// === Structs ===

public struct Redemption has key {
    id: UID,
    merchant_id: ID,
    customer: address,
    funds: Balance<LOYALTY>,
    /// `sha3_256(code)`. Merchant submits preimage at `verify`; Move re-hashes.
    code_hash: vector<u8>,
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
    code_hash: vector<u8>,
    ttl_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Redemption {
    assert!(code_hash.length() > 0, EEmptyCodeHash);
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
        code_hash,
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

/// Merchant verifies the preimage and burns the held balance. Consumes the Redemption.
public fun verify(
    merchant: &mut Merchant,
    cap: &MerchantCap,
    redemption: Redemption,
    code: vector<u8>,
    clock: &Clock,
) {
    merchant.assert_cap_matches(cap);

    let merchant_id_now = object::id(merchant);
    let redemption_id = object::id(&redemption);
    let now = clock.timestamp_ms();

    assert!(redemption.merchant_id == merchant_id_now, EWrongMerchantForRedemption);
    assert!(now < redemption.expires_at_ms, EExpired);
    assert!(hash::sha3_256(code) == redemption.code_hash, EWrongCode);

    let Redemption { id, merchant_id, customer, funds, .. } = redemption;
    let amount = funds.value();
    balance::decrease_supply(
        coin::supply_mut(merchant.loyalty_treasury_cap_mut()),
        funds,
    );
    id.delete();

    events::emit_redemption_verified(redemption_id, merchant_id, customer, amount);
}
