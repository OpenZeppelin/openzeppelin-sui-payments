/// Redemption flow — extracts loyalty balance from the customer's PAS Account into a
/// `Hold` shared object, then either:
///   - merchant `verify`s the preimage to the stored hash → balance is burned, OR
///   - `release` is called (permissionless) after expiry → balance returns to customer.
///
/// `request_redeem` PTB shape:
///   auth    = account::new_auth(&ctx)
///   request = customer_loyalty_account.unlock_balance<LOYALTY>(&auth, amount, &ctx)
///   redemption::request_redeem(merchant, request, policy_loyalty,
///                              code_hash, ttl_ms, &clock, ctx)
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
const EZeroAmount: vector<u8> = b"Hold amount must be greater than zero";
#[error(code = 3)]
const EWrongMerchantForHold: vector<u8> = b"Hold was not created for this Merchant";
#[error(code = 4)]
const EExpired: vector<u8> = b"Hold has expired";
#[error(code = 5)]
const ENotExpired: vector<u8> = b"Hold has not yet expired";
#[error(code = 6)]
const EWrongCode: vector<u8> = b"Code does not match commitment";
#[error(code = 7)]
const EWrongCustomer: vector<u8> = b"Account owner does not match Hold customer";

// === Structs ===

public struct Hold has key {
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
/// resulting balance in a fresh shared `Hold`.
public fun request_redeem(
    merchant: &Merchant,
    mut request: Request<UnlockFunds<Balance<LOYALTY>>>,
    policy_loyalty: &Policy<Balance<LOYALTY>>,
    code_hash: vector<u8>,
    ttl_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(code_hash.length() > 0, EEmptyCodeHash);
    assert!(ttl_ms > 0, EZeroTtl);

    let merchant_id = object::id(merchant);
    let customer = request.data().owner();
    let amount = request.data().funds().value();
    assert!(amount > 0, EZeroAmount);

    request.approve(loyalty::new_redeem_unlock_approval());
    let funds: Balance<LOYALTY> = unlock_funds::resolve(request, policy_loyalty);

    let expires_at_ms = clock.timestamp_ms() + ttl_ms;
    let hold = Hold {
        id: object::new(ctx),
        merchant_id,
        customer,
        funds,
        code_hash,
        expires_at_ms,
    };
    let hold_id = object::id(&hold);
    transfer::share_object(hold);

    events::emit_redeem_requested(hold_id, merchant_id, customer, amount, expires_at_ms);
}

/// Permissionless release after expiry — returns the held balance to the customer's
/// loyalty Account. Prevents griefing by an inactive merchant.
public fun release(hold: Hold, customer_loyalty_account: &Account, clock: &Clock) {
    let hold_id = object::id(&hold);
    let now = clock.timestamp_ms();

    assert!(now >= hold.expires_at_ms, ENotExpired);
    assert!(customer_loyalty_account.owner() == hold.customer, EWrongCustomer);

    let Hold { id, merchant_id, customer, funds, .. } = hold;
    let amount = funds.value();
    customer_loyalty_account.deposit_balance(funds);
    id.delete();

    events::emit_redemption_released(hold_id, merchant_id, customer, amount);
}

// === Admin Functions ===

/// Merchant verifies the preimage and burns the held balance. Consumes the Hold.
public fun verify(
    merchant: &mut Merchant,
    cap: &MerchantCap,
    hold: Hold,
    code: vector<u8>,
    clock: &Clock,
) {
    merchant.assert_cap_matches(cap);

    let merchant_id_now = object::id(merchant);
    let hold_id = object::id(&hold);
    let now = clock.timestamp_ms();

    assert!(hold.merchant_id == merchant_id_now, EWrongMerchantForHold);
    assert!(now < hold.expires_at_ms, EExpired);
    assert!(hash::sha3_256(code) == hold.code_hash, EWrongCode);

    let Hold { id, merchant_id, customer, funds, .. } = hold;
    let amount = funds.value();
    balance::decrease_supply(
        coin::supply_mut(merchant.loyalty_treasury_cap_mut()),
        funds,
    );
    id.delete();

    events::emit_redemption_verified(hold_id, merchant_id, customer, amount);
}
