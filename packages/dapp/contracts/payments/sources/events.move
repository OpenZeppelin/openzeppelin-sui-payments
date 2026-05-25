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

public struct RedemptionCreated has copy, drop {
    redemption_id: ID,
    merchant_id: ID,
    customer: address,
    amount: u64,
    expires_at_ms: u64,
}

public struct RedemptionVerified has copy, drop {
    redemption_id: ID,
    merchant_id: ID,
    customer: address,
    amount: u64,
}

public struct RedemptionReleased has copy, drop {
    redemption_id: ID,
    merchant_id: ID,
    customer: address,
    amount: u64,
}

// === Package Functions ===

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

public(package) fun emit_redemption_created(
    redemption_id: ID,
    merchant_id: ID,
    customer: address,
    amount: u64,
    expires_at_ms: u64,
) {
    event::emit(RedemptionCreated {
        redemption_id,
        merchant_id,
        customer,
        amount,
        expires_at_ms,
    });
}

public(package) fun emit_redemption_verified(
    redemption_id: ID,
    merchant_id: ID,
    customer: address,
    amount: u64,
) {
    event::emit(RedemptionVerified { redemption_id, merchant_id, customer, amount });
}

public(package) fun emit_redemption_released(
    redemption_id: ID,
    merchant_id: ID,
    customer: address,
    amount: u64,
) {
    event::emit(RedemptionReleased { redemption_id, merchant_id, customer, amount });
}
