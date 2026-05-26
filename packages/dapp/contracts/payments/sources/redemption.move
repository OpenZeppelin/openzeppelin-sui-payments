module openzeppelin_payments::redemption;

use openzeppelin_payments::events;
use openzeppelin_payments::loyalty::{Self, LOYALTY};
use openzeppelin_payments::merchant::{Merchant, MerchantCap};
use pas::policy::Policy;
use pas::request::Request;
use pas::unlock_funds::{Self, UnlockFunds};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin;

// === Errors ===

#[error(code = 0)]
const EZeroAmount: vector<u8> = b"Voucher amount must be greater than zero";
#[error(code = 1)]
const EZeroTtl: vector<u8> = b"ttl_ms must be greater than zero";
#[error(code = 2)]
const EWrongMerchantForVoucher: vector<u8> =
    b"Voucher was not created for this Merchant";
#[error(code = 3)]
const EExpired: vector<u8> = b"Voucher has expired";
#[error(code = 4)]
const ENotExpired: vector<u8> = b"Voucher has not yet expired";
#[error(code = 5)]
const EAmountMismatch: vector<u8> =
    b"Unlock amount does not match Voucher amount";

// === Structs ===

/// Merchant-issued voucher entitling the holder to redeem `amount` LOYALTY in
/// exchange for a service. Customer scans the `id` and consumes the voucher via
/// `redeem`, atomically burning their loyalty.
public struct RedemptionVoucher has key {
    id: UID,
    merchant_id: ID,
    amount: u64,
    expires_at_ms: u64,
}

// === Public Functions ===

/// Customer redeems the voucher. Consumes the voucher, approves + resolves the
/// customer's unlock request (which extracts `amount` LOYALTY from their Account),
/// burns the balance via the merchant's `TreasuryCap`, and emits `VoucherRedeemed`.
public fun redeem(
    m: &mut Merchant,
    voucher: RedemptionVoucher,
    mut unlock_req: Request<UnlockFunds<Balance<LOYALTY>>>,
    policy_loyalty: &Policy<Balance<LOYALTY>>,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let now = clock.timestamp_ms();
    let voucher_id = object::id(&voucher);
    let merchant_id = object::id(m);

    // Voucher validity
    assert!(voucher.merchant_id == merchant_id, EWrongMerchantForVoucher);
    assert!(now < voucher.expires_at_ms, EExpired);

    // Unlock-request integrity
    let customer = unlock_req.data().owner();
    let unlock_amount = unlock_req.data().funds().value();
    assert!(unlock_amount == voucher.amount, EAmountMismatch);

    // Snapshot before consume
    let amount = voucher.amount;

    // Approve unlock with our package-private witness, resolve via policy → raw Balance
    unlock_req.approve(loyalty::new_redeem_unlock_approval());
    let funds: Balance<LOYALTY> = unlock_funds::resolve(unlock_req, policy_loyalty);

    // Burn
    balance::decrease_supply(
        coin::supply_mut(m.loyalty_treasury_cap_mut()),
        funds,
    );

    // Destroy voucher
    let RedemptionVoucher { id, .. } = voucher;
    id.delete();

    events::emit_voucher_redeemed(voucher_id, merchant_id, customer, amount, now);
}

/// Share the voucher.
public fun share_voucher(voucher: RedemptionVoucher) {
    transfer::share_object(voucher);
}

/// Permissionless cleanup of an expired voucher. No balance is held by the voucher
/// (customer balance stays in their Account until settlement), so this is just
/// object destruction.
public fun cancel_voucher(voucher: RedemptionVoucher, clock: &Clock) {
    assert!(clock.timestamp_ms() >= voucher.expires_at_ms, ENotExpired);
    let RedemptionVoucher { id, .. } = voucher;
    id.delete();
}

// === Admin Functions ===

/// Merchant creates a redemption voucher.
public fun create_voucher(
    m: &Merchant,
    cap: &MerchantCap,
    amount: u64,
    ttl_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): RedemptionVoucher {
    m.assert_cap_matches(cap);
    assert!(amount > 0, EZeroAmount);
    assert!(ttl_ms > 0, EZeroTtl);

    RedemptionVoucher {
        id: object::new(ctx),
        merchant_id: object::id(m),
        amount,
        expires_at_ms: clock.timestamp_ms() + ttl_ms,
    }
}
