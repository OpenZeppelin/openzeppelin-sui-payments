/// Invoice — merchant-issued payment intent + customer-side settlement.
///
/// Merchant POS issues an `Invoice` via `invoice::new(m, &cap, ...)` (cap-gated), then
/// `invoice::share(invoice)` and surfaces the object ID through a QR. Customer scans
/// and calls `invoice::pay<S>(...)`, which resolves the customer's already-approved
/// PAS `send_funds` request (transfers stablecoin into the merchant's PAS Account),
/// mints loyalty rewards into the customer's PAS Account, destroys the Invoice, and
/// emits `InvoicePaid`.
///
/// Cleanup: `invoice::cancel(invoice, &clock)` (permissionless after expiry).
module openzeppelin_payments::invoice;

use openzeppelin_payments::events;
use openzeppelin_payments::loyalty;
use openzeppelin_payments::merchant::{Self, Merchant, MerchantCap};
use pas::account::Account;
use pas::policy::Policy;
use pas::request::Request;
use pas::send_funds::{Self, SendFunds};
use sui::balance::Balance;
use sui::clock::Clock;

// === Errors ===

#[error(code = 0)]
const EZeroAmount: vector<u8> = b"Invoice amount must be greater than zero";
#[error(code = 1)]
const EZeroTtl: vector<u8> = b"Invoice ttl_ms must be greater than zero";
#[error(code = 2)]
const ENotExpired: vector<u8> = b"Invoice has not yet expired";
#[error(code = 3)]
const EWrongMerchantForInvoice: vector<u8> =
    b"Invoice was not created for this Merchant";
#[error(code = 4)]
const EInvoiceExpired: vector<u8> = b"Invoice has expired";
#[error(code = 5)]
const EAmountMismatch: vector<u8> =
    b"Send amount does not match Invoice amount";
#[error(code = 6)]
const EWrongRecipient: vector<u8> =
    b"Send recipient does not match Invoice payout_address";
#[error(code = 7)]
const EWrongLoyaltyRecipient: vector<u8> =
    b"Loyalty account owner does not match payer";

// === Structs ===

/// Merchant-issued invoice. Customer scans `id` from a QR and settles via `pay`.
public struct Invoice has key {
    id: UID,
    merchant_id: ID,
    payout_address: address,
    amount: u64,
    order_ref: vector<u8>,
    expires_at_ms: u64,
}

// === Public Functions ===

/// Merchant issues an Invoice. Cap check + amount/ttl validation happen here.
/// Returns the `Invoice` for the caller to `share` and surface as a QR.
public fun new(
    merchant: &Merchant,
    _: &MerchantCap,
    amount: u64,
    order_ref: vector<u8>,
    ttl_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Invoice {
    assert!(amount > 0, EZeroAmount);
    assert!(ttl_ms > 0, EZeroTtl);

    Invoice {
        id: object::new(ctx),
        merchant_id: object::id(merchant),
        payout_address: merchant::payout_address(merchant),
        amount,
        order_ref,
        expires_at_ms: clock.timestamp_ms() + ttl_ms,
    }
}

/// Share the `Invoice`. Required because it is `key`-only (no `store`), so
/// `transfer::share_object` is restricted to this module.
public fun share(invoice: Invoice) {
    transfer::share_object(invoice);
}

/// Customer settles the invoice. Resolves the customer's already-approved stablecoin
/// `send_funds` request (transfers `Balance<S>` from customer's PAS Account to the
/// merchant's), mints loyalty rewards into the customer's PAS `Account<LOYALTY>`,
/// destroys the Invoice, and emits `InvoicePaid`.
public fun pay<S>(
    m: &mut Merchant,
    invoice: Invoice,
    send_request: Request<SendFunds<Balance<S>>>,
    policy_s: &Policy<Balance<S>>,
    customer_loyalty_account: &Account,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let now = clock.timestamp_ms();
    let invoice_id = object::id(&invoice);
    let merchant_id = object::id(m);

    // Invoice validity
    assert!(invoice.merchant_id == merchant_id, EWrongMerchantForInvoice);
    assert!(now < invoice.expires_at_ms, EInvoiceExpired);

    // Send-request integrity
    let data = send_request.data();
    let sender = data.sender();
    assert!(data.recipient() == invoice.payout_address, EWrongRecipient);
    assert!(data.funds().value() == invoice.amount, EAmountMismatch);

    // Loyalty mints to the payer's own account
    assert!(customer_loyalty_account.owner() == sender, EWrongLoyaltyRecipient);

    // Snapshot mint params (immutable read) and consume the invoice
    let (num, den, max) = merchant::mint_params(m);
    let Invoice { id, amount: payment_amount, order_ref, .. } = invoice;
    id.delete();

    // Resolve send_funds — transfers stablecoin into the merchant's PAS Account
    send_funds::resolve_balance(send_request, policy_s);

    // Compute and mint loyalty
    let raw: u128 = (payment_amount as u128) * (num as u128) / (den as u128);
    let mint_amount: u64 = if (raw > (max as u128)) { max } else { (raw as u64) };
    if (mint_amount > 0) {
        loyalty::mint_into(
            merchant::loyalty_treasury_cap_mut(m),
            customer_loyalty_account,
            mint_amount,
        );
    };

    events::emit_invoice_paid(
        invoice_id,
        merchant_id,
        order_ref,
        sender,
        payment_amount,
        mint_amount,
        now,
    );
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
