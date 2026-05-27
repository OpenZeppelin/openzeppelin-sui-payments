/// Redemption — merchant-issued `RedemptionVoucher`. This module owns the struct,
/// its lifecycle helpers (`share`, `cancel`, pkg `new` / `destroy`), and read
/// accessors. Voucher issuance (`merchant::create_voucher`) and customer-side
/// settlement (`merchant::redeem`) live in `merchant.move` to avoid a module
/// dependency cycle on `Merchant` / `MerchantCap`.
///
/// Lifecycle:
///   Merchant POS:
///     voucher = merchant::create_voucher(m, &cap, amount, ttl_ms, &clock, ctx)
///     redemption::share(voucher)
///     -- QR encodes voucher's object ID --
///
///   Customer wallet (after scanning QR):
///     auth       = account::new_auth(&ctx)
///     unlock_req = customer_LOY.unlock_balance<LOYALTY>(&auth, voucher.amount(), &ctx)
///     merchant::redeem(m, voucher, unlock_req, policy_loyalty, &clock, ctx)
///
///   Cleanup (after expiry, permissionless):
///     redemption::cancel(voucher, &clock)
module openzeppelin_payments::redemption;

use sui::clock::Clock;

// === Errors ===

#[error(code = 0)]
const EZeroAmount: vector<u8> = b"Voucher amount must be greater than zero";
#[error(code = 1)]
const EZeroTtl: vector<u8> = b"Voucher ttl_ms must be greater than zero";
#[error(code = 2)]
const ENotExpired: vector<u8> = b"Voucher has not yet expired";

// === Structs ===

/// Merchant-issued voucher entitling the holder to redeem `amount` LOYALTY in
/// exchange for a service. Customer scans the `id` and consumes the voucher via
/// `merchant::redeem`, atomically burning their loyalty.
public struct RedemptionVoucher has key {
    id: UID,
    merchant_id: ID,
    amount: u64,
    expires_at_ms: u64,
}

// === Public Functions ===

/// Share the `RedemptionVoucher`. Required because it is `key`-only (no `store`), so
/// `transfer::share_object` is restricted to this module.
public fun share(voucher: RedemptionVoucher) {
    transfer::share_object(voucher);
}

/// Permissionless cleanup of an expired voucher. No balance is held by the voucher
/// (customer balance stays in their Account until settlement), so this is just
/// object destruction.
public fun cancel(voucher: RedemptionVoucher, clock: &Clock) {
    assert!(clock.timestamp_ms() >= voucher.expires_at_ms, ENotExpired);
    let RedemptionVoucher { id, .. } = voucher;
    id.delete();
}

// === View Functions ===

public fun merchant_id(v: &RedemptionVoucher): ID { v.merchant_id }
public fun amount(v: &RedemptionVoucher): u64 { v.amount }
public fun expires_at_ms(v: &RedemptionVoucher): u64 { v.expires_at_ms }

// === Package Functions ===

/// Construct a voucher. Only `merchant::create_voucher` calls this — the cap check
/// happens there; field-level invariants (`amount > 0`, `ttl_ms > 0`) are enforced
/// here so any future construction path inherits the same guarantees.
public(package) fun new(
    merchant_id: ID,
    amount: u64,
    ttl_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): RedemptionVoucher {
    assert!(amount > 0, EZeroAmount);
    assert!(ttl_ms > 0, EZeroTtl);
    RedemptionVoucher {
        id: object::new(ctx),
        merchant_id,
        amount,
        expires_at_ms: clock.timestamp_ms() + ttl_ms,
    }
}

/// Consume a voucher. Called by `merchant::redeem` after burning. Fields are
/// package-private so destruction must happen in this module.
public(package) fun destroy(voucher: RedemptionVoucher) {
    let RedemptionVoucher { id, .. } = voucher;
    id.delete();
}
