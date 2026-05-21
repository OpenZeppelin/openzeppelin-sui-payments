/// Centralised event definitions for the payments package.
///
/// Modeled after `openzeppelin-sui-amm::events`: event structs in one place, plus
/// package-private `emit_*` helpers. Call sites use the helpers rather than
/// constructing the struct and calling `event::emit` directly — keeps the event
/// surface, field order, and naming in one file.
module openzeppelin_payments::events;

use sui::event;

// === Events ===

public struct PaymentEvent has copy, drop {
    merchant_id: ID,
    order_ref: vector<u8>,
    customer: address,
    amount: u64,
    loyalty_minted: u64,
    timestamp_ms: u64,
}

public struct RedeemRequested has copy, drop {
    hold_id: ID,
    merchant_id: ID,
    customer: address,
    amount: u64,
    expires_at_ms: u64,
}

public struct RedemptionVerified has copy, drop {
    hold_id: ID,
    merchant_id: ID,
    customer: address,
    amount: u64,
}

public struct RedemptionReleased has copy, drop {
    hold_id: ID,
    merchant_id: ID,
    customer: address,
    amount: u64,
}

// === Emit helpers (package-private) ===

public(package) fun emit_payment(
    merchant_id: ID,
    order_ref: vector<u8>,
    customer: address,
    amount: u64,
    loyalty_minted: u64,
    timestamp_ms: u64,
) {
    event::emit(PaymentEvent {
        merchant_id,
        order_ref,
        customer,
        amount,
        loyalty_minted,
        timestamp_ms,
    });
}

public(package) fun emit_redeem_requested(
    hold_id: ID,
    merchant_id: ID,
    customer: address,
    amount: u64,
    expires_at_ms: u64,
) {
    event::emit(RedeemRequested {
        hold_id,
        merchant_id,
        customer,
        amount,
        expires_at_ms,
    });
}

public(package) fun emit_redemption_verified(
    hold_id: ID,
    merchant_id: ID,
    customer: address,
    amount: u64,
) {
    event::emit(RedemptionVerified { hold_id, merchant_id, customer, amount });
}

public(package) fun emit_redemption_released(
    hold_id: ID,
    merchant_id: ID,
    customer: address,
    amount: u64,
) {
    event::emit(RedemptionReleased { hold_id, merchant_id, customer, amount });
}
