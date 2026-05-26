module openzeppelin_payments::invoice;

use sui::clock::Clock;

// === Errors ===

#[error(code = 0)]
const ENotExpired: vector<u8> = b"Invoice has not yet expired";

// === Structs ===

/// Merchant-issued invoice. Customer scans `id` from a QR and settles via
/// `merchant::pay`.
public struct Invoice has key {
    id: UID,
    merchant_id: ID,
    payout_address: address,
    amount: u64,
    order_ref: vector<u8>,
    expires_at_ms: u64,
}

// === Public Functions ===

/// Share the `Invoice`. Required because it is `key`-only (no `store`), so
/// `transfer::share_object` is restricted to this module.
public fun share(invoice: Invoice) {
    transfer::share_object(invoice);
}

/// Permissionless cleanup of an expired Invoice. No balance is held by the Invoice
/// (customer balance stays in their Account until settlement), so this is just
/// object destruction.
public fun cancel(invoice: Invoice, clock: &Clock) {
    assert!(clock.timestamp_ms() >= invoice.expires_at_ms, ENotExpired);
    let Invoice { id, .. } = invoice;
    id.delete();
}

// === View Functions ===

public fun merchant_id(i: &Invoice): ID { i.merchant_id }
public fun payout_address(i: &Invoice): address { i.payout_address }
public fun amount(i: &Invoice): u64 { i.amount }
public fun order_ref(i: &Invoice): &vector<u8> { &i.order_ref }
public fun expires_at_ms(i: &Invoice): u64 { i.expires_at_ms }

// === Package Functions ===

/// Construct an Invoice. Only `merchant::issue_invoice` calls this — the cap check
/// and amount/ttl validation happen there.
public(package) fun new(
    merchant_id: ID,
    payout_address: address,
    amount: u64,
    order_ref: vector<u8>,
    expires_at_ms: u64,
    ctx: &mut TxContext,
): Invoice {
    Invoice {
        id: object::new(ctx),
        merchant_id,
        payout_address,
        amount,
        order_ref,
        expires_at_ms,
    }
}

/// Consume an Invoice. Called by `merchant::pay` after settlement to destroy the
/// object. Fields are package-private so destruction must happen in this module.
public(package) fun destroy(invoice: Invoice) {
    let Invoice { id, .. } = invoice;
    id.delete();
}
