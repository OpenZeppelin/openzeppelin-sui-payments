/// Centralised event definitions for the payments package.
///
/// Modeled after `openzeppelin-sui-amm::events`: event structs in one place, plus
/// package-private `emit_*` helpers. Call sites use the helpers rather than
/// constructing the struct and calling `event::emit` directly.
module openzeppelin_payments::events;

use sui::event;

// === Events ===

/// Emitted when a customer settles an `Invoice`. Indexer subscribes filtered by
/// `merchant_id` and resolves `invoice_id`/`order_ref` → settled.
public struct InvoicePaid has copy, drop {
    invoice_id: ID,
    merchant_id: ID,
    order_ref: vector<u8>,
    customer: address,
    amount: u64,
    loyalty_minted: u64,
    timestamp_ms: u64,
}

/// Emitted when a customer redeems a `RedemptionVoucher`. Indexer subscribes filtered
/// by `merchant_id` and resolves `voucher_id` → redeemed.
public struct VoucherRedeemed has copy, drop {
    voucher_id: ID,
    merchant_id: ID,
    customer: address,
    amount: u64,
    timestamp_ms: u64,
}

// === Package Functions ===

public(package) fun emit_invoice_paid(
    invoice_id: ID,
    merchant_id: ID,
    order_ref: vector<u8>,
    customer: address,
    amount: u64,
    loyalty_minted: u64,
    timestamp_ms: u64,
) {
    event::emit(InvoicePaid {
        invoice_id,
        merchant_id,
        order_ref,
        customer,
        amount,
        loyalty_minted,
        timestamp_ms,
    });
}

public(package) fun emit_voucher_redeemed(
    voucher_id: ID,
    merchant_id: ID,
    customer: address,
    amount: u64,
    timestamp_ms: u64,
) {
    event::emit(VoucherRedeemed {
        voucher_id,
        merchant_id,
        customer,
        amount,
        timestamp_ms,
    });
}
