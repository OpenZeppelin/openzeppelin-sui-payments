/// Receipts - on-chain proof of settlement, stored in the `Merchant`.
///
/// `Receipt<Payment>` is built at the end of `merchant::pay` and
/// `merchant::pay_with_coin` and stored in `Merchant.invoice_receipts`.
/// `Receipt<Redemption>` is built at the end of `merchant::redeem` and stored in
/// `Merchant.voucher_receipts`. Both are keyed
/// by the originating invoice/voucher ID and record the settling `customer` for
/// attribution. `T` is the flow-specific payload (`Payment` / `Redemption`): the
/// generic keeps the shared fields in one place while giving each flow a
/// statically-typed payload, so payload accessors are total (no runtime
/// "wrong receipt kind" checks).
///
/// This module also hosts the shared `Item` line type and the merchant-agnostic
/// helpers `new_item` (dumb constructor - pricing is resolved by `merchant`) and
/// `compute_total`. It has no dependency on `merchant`, so `merchant` can store
/// `Receipt` values without creating a dependency cycle.
module openzeppelin_payments::receipt;

use std::type_name::TypeName;

// === Errors ===

#[error(code = 0)]
const EAmountOverflow: vector<u8> = "Amount exceeds u64 range";

// === Structs ===

/// One line on an `Invoice` or a `Voucher` - a quantity of a specific listing
/// variant at a snapshotted unit price. The price is in stablecoin units for
/// invoices and `LOYALTY` units for vouchers; the type is the same so it can
/// be reused across both flows. Snapshot pricing decouples the order from
/// later mutations of the underlying `Variant`.
public struct Item has drop, store {
    /// ID of the listing variant this line refers to.
    variant_id: ID,
    /// Quantity ordered.
    quantity: u64,
    /// Snapshot unit price (stablecoin units for invoices, LOYALTY units for vouchers).
    price: u64,
}

/// Proof of settlement, stored as a value in the merchant's receipt tables.
/// `store`-only (no `key`): identity is the `Table` key (the originating
/// invoice/voucher ID), not an object UID. `T` is the flow-specific payload
/// (`Payment` or `Redemption`).
public struct Receipt<T: store> has store {
    /// The paying/redeeming customer the receipt is attributed to.
    customer: address,
    /// Line items copied from the originating invoice or voucher.
    items: vector<Item>,
    /// Total settled amount (stablecoin for payment, LOYALTY for redemption).
    amount: u64,
    /// Settlement clock timestamp (ms since epoch).
    timestamp_ms: u64,
    /// Flow-specific payload (`Payment` or `Redemption`).
    data: T,
}

/// Payment-flow payload (carried inside `Receipt<Payment>`).
public struct Payment has drop, store {
    /// ID of the `Invoice` this receipt settled.
    invoice_id: ID,
    /// Payout address that received the stablecoin.
    payout_address: address,
    /// `TypeName` of the stablecoin the customer paid in.
    payment_type: TypeName,
    /// LOYALTY units minted to the customer on settlement.
    loyalty: u64,
    /// Merchant-supplied order reference carried over from the invoice.
    order_ref: vector<u8>,
}

/// Redemption-flow payload (carried inside `Receipt<Redemption>`).
public struct Redemption has drop, store {
    /// ID of the `Voucher` this receipt settled.
    voucher_id: ID,
}

// === View Functions ===

/// ID of the listing variant this line refers to.
public fun variant_id(self: &Item): ID { self.variant_id }

/// Quantity ordered.
public fun quantity(self: &Item): u64 { self.quantity }

/// Snapshot unit price (stablecoin units for invoices, LOYALTY units for vouchers).
public fun price(self: &Item): u64 { self.price }

/// The customer the receipt is attributed to.
public fun customer<T: store>(self: &Receipt<T>): address { self.customer }

/// Line items copied from the originating invoice or voucher.
public fun items<T: store>(self: &Receipt<T>): &vector<Item> { &self.items }

/// Total settled amount (stablecoin for payment, LOYALTY for redemption).
public fun amount<T: store>(self: &Receipt<T>): u64 { self.amount }

/// Settlement timestamp (ms since epoch).
public fun timestamp_ms<T: store>(self: &Receipt<T>): u64 { self.timestamp_ms }

/// ID of the `Invoice` this receipt settled.
public fun invoice_id(self: &Receipt<Payment>): ID { self.data.invoice_id }

/// Payout address recorded at settlement.
public fun payout_address(self: &Receipt<Payment>): address { self.data.payout_address }

/// `TypeName` of the stablecoin the customer paid in.
public fun payment_type(self: &Receipt<Payment>): TypeName { self.data.payment_type }

/// LOYALTY units minted to the customer on settlement.
public fun loyalty(self: &Receipt<Payment>): u64 { self.data.loyalty }

/// Merchant-supplied order reference carried over from the invoice.
public fun order_ref(self: &Receipt<Payment>): &vector<u8> { &self.data.order_ref }

/// ID of the `Voucher` this receipt settled.
public fun voucher_id(self: &Receipt<Redemption>): ID { self.data.voucher_id }

// === Package Functions ===

/// Merchant-agnostic line constructor. Pricing (catalog lookup + active check)
/// is resolved by `merchant` before calling this, so `receipt` stays free of any
/// `merchant` dependency.
///
/// #### Parameters
/// - `variant_id`: ID of the variant this line bills.
/// - `quantity`: Quantity ordered.
/// - `price`: Snapshotted unit price (stablecoin or LOYALTY units).
///
/// #### Returns
/// - The constructed `Item`.
public(package) fun new_item(variant_id: ID, quantity: u64, price: u64): Item {
    Item { variant_id, quantity, price }
}

/// Sum `item.quantity * item.price` across all items.
///
/// Each multiply and add is checked, so the total never wraps.
///
/// #### Parameters
/// - `items`: The line items to total.
///
/// #### Returns
/// - The summed amount.
///
/// #### Aborts
/// - `EAmountOverflow` if any intermediate product or the running total exceeds
///   the `u64` range.
public(package) fun compute_total(items: &vector<Item>): u64 {
    let mut total: u64 = 0;
    items.do_ref!(|item| {
        let position_total = item
            .quantity
            .checked_mul(item.price)
            .destroy_or!(abort EAmountOverflow);
        total = total.checked_add(position_total).destroy_or!(abort EAmountOverflow);
    });

    total
}

/// Build a `Receipt<Payment>`.
///
/// #### Parameters
/// - `customer`: The paying customer the receipt is attributed to.
/// - `items`: Line items copied from the originating invoice.
/// - `amount`: Total settled stablecoin amount.
/// - `timestamp_ms`: Settlement clock timestamp (ms since epoch).
/// - `invoice_id`: ID of the `Invoice` this receipt settled.
/// - `payout_address`: Payout address that received the stablecoin.
/// - `payment_type`: `TypeName` of the stablecoin the customer paid in.
/// - `loyalty`: LOYALTY units minted to the customer on settlement.
/// - `order_ref`: Merchant-supplied order reference carried over from the invoice.
///
/// #### Returns
/// - The constructed `Receipt<Payment>`.
public(package) fun new_payment(
    customer: address,
    items: vector<Item>,
    amount: u64,
    timestamp_ms: u64,
    invoice_id: ID,
    payout_address: address,
    payment_type: TypeName,
    loyalty: u64,
    order_ref: vector<u8>,
): Receipt<Payment> {
    Receipt {
        customer,
        items,
        amount,
        timestamp_ms,
        data: Payment { invoice_id, payout_address, payment_type, loyalty, order_ref },
    }
}

/// Build a `Receipt<Redemption>`.
///
/// #### Parameters
/// - `customer`: The redeeming customer the receipt is attributed to.
/// - `items`: Line items copied from the originating voucher.
/// - `amount`: Total redeemed LOYALTY amount.
/// - `timestamp_ms`: Settlement clock timestamp (ms since epoch).
/// - `voucher_id`: ID of the `Voucher` this receipt settled.
///
/// #### Returns
/// - The constructed `Receipt<Redemption>`.
public(package) fun new_redemption(
    customer: address,
    items: vector<Item>,
    amount: u64,
    timestamp_ms: u64,
    voucher_id: ID,
): Receipt<Redemption> {
    Receipt {
        customer,
        items,
        amount,
        timestamp_ms,
        data: Redemption { voucher_id },
    }
}

/// Destroy a receipt, reclaiming its storage. Used by the merchant's prune
/// path; the `InvoicePaid` / `VoucherRedeemed` event keeps totals + metadata,
/// but the `items` line-item breakdown is lost.
///
/// #### Parameters
/// - `receipt`: The receipt to destroy.
public(package) fun destroy<T: store + drop>(receipt: Receipt<T>) {
    let Receipt { customer: _, items: _, amount: _, timestamp_ms: _, data: _ } = receipt;
}
