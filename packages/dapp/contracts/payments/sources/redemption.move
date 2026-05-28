/// Redemption — merchant-issued `Voucher` + customer-side settlement.
///
/// Merchant POS issues a voucher via `redemption::new(m, &cap, ...)` (cap-gated),
/// then `redemption::share(voucher)` and surfaces the object ID through a QR.
/// Customer scans and calls `redemption::redeem(...)`, which resolves the customer's
/// unlock request (extracts `amount` LOYALTY from their Account), burns the balance,
/// destroys the voucher, and emits `VoucherRedeemed`.
///
/// Cleanup: `redemption::cancel(voucher, &clock)` (permissionless after expiry).
///
/// Customer's loyalty balance is never locked between voucher issuance and redemption
/// — it stays in their Account until they actively settle. If they walk away, the
/// voucher just expires; nothing was taken from them.
module openzeppelin_payments::redemption;

use openzeppelin_payments::events;
use openzeppelin_payments::loyalty::{Self, LOYALTY};
use openzeppelin_payments::merchant::{Self, Merchant, MerchantCap};
use pas::policy::Policy;
use pas::request::Request;
use pas::unlock_funds::{Self, UnlockFunds};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin;

// === Errors ===

#[error(code = 0)]
const EWrongMerchantCap: vector<u8> = b"MerchantCap does not match this Merchant";
#[error(code = 1)]
const EZeroAmount: vector<u8> = b"Voucher amount must be greater than zero";
#[error(code = 2)]
const EZeroTtl: vector<u8> = b"Voucher ttl_ms must be greater than zero";
#[error(code = 3)]
const ENotExpired: vector<u8> = b"Voucher has not yet expired";
#[error(code = 4)]
const EWrongMerchantForVoucher: vector<u8> =
    b"Voucher was not created for this Merchant";
#[error(code = 5)]
const EVoucherExpired: vector<u8> = b"Voucher has expired";
#[error(code = 6)]
const EAmountMismatch: vector<u8> =
    b"Unlock amount does not match Voucher amount";

// === Structs ===

/// Merchant-issued voucher entitling the holder to redeem `amount` LOYALTY in
/// exchange for a service. Customer scans the `id` and consumes the voucher via
/// `redeem`, atomically burning their loyalty.
public struct Voucher has key {
    id: UID,
    merchant_id: ID,
    amount: u64,
    expires_at_ms: u64,
}

// === Public Functions ===

/// Merchant issues a voucher. Cap check + amount/ttl validation happen here.
public fun new(
    m: &Merchant,
    cap: &MerchantCap,
    amount: u64,
    ttl_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Voucher {
    assert!(object::id(m) == merchant::merchant_id(cap), EWrongMerchantCap);
    assert!(amount > 0, EZeroAmount);
    assert!(ttl_ms > 0, EZeroTtl);

    Voucher {
        id: object::new(ctx),
        merchant_id: object::id(m),
        amount,
        expires_at_ms: clock.timestamp_ms() + ttl_ms,
    }
}

/// Share the voucher. Required because it is `key`-only (no `store`), so
/// `transfer::share_object` is restricted to this module.
public fun share(voucher: Voucher) {
    transfer::share_object(voucher);
}

/// Customer redeems the voucher. Resolves the customer's unlock request (extracts
/// `amount` LOYALTY from their PAS Account), burns the balance via the merchant's
/// `TreasuryCap`, destroys the voucher, and emits `VoucherRedeemed`.
public fun redeem(
    m: &mut Merchant,
    voucher: Voucher,
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
    assert!(now < voucher.expires_at_ms, EVoucherExpired);

    // Unlock-request integrity
    let customer = unlock_req.data().owner();
    let unlock_amount = unlock_req.data().funds().value();
    assert!(unlock_amount == voucher.amount, EAmountMismatch);

    // Consume voucher
    let Voucher { id, amount, .. } = voucher;
    id.delete();

    // Approve + resolve → raw Balance
    unlock_req.approve(loyalty::new_redeem_unlock_approval());
    let funds: Balance<LOYALTY> = unlock_funds::resolve(unlock_req, policy_loyalty);

    // Burn
    balance::decrease_supply(
        coin::supply_mut(merchant::loyalty_treasury_cap_mut(m)),
        funds,
    );

    events::emit_voucher_redeemed(voucher_id, merchant_id, customer, amount, now);
}

/// Permissionless cleanup of an expired voucher. No balance is held by the voucher,
/// so this is just object destruction.
public fun cancel(voucher: Voucher, clock: &Clock) {
    assert!(clock.timestamp_ms() >= voucher.expires_at_ms, ENotExpired);
    let Voucher { id, .. } = voucher;
    id.delete();
}

// === View Functions ===

public fun merchant_id(v: &Voucher): ID { v.merchant_id }
public fun amount(v: &Voucher): u64 { v.amount }
public fun expires_at_ms(v: &Voucher): u64 { v.expires_at_ms }
