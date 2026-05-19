/// Payment orchestration — generic over the PAS stablecoin type `S`.
///
/// `pay<S>` is the single atomic entry that:
///   1. Resolves the customer's already-approved `Request<SendFunds<Balance<S>>>` via
///      the stablecoin's `Policy<Balance<S>>`, moving the stablecoin from the
///      customer's PAS Account into the merchant's payout Account.
///   2. Mints loyalty into the customer's `Account<LOYALTY>` at the rate stored on
///      `Merchant`, bounded by `max_mint_per_payment`.
///   3. Emits `PaymentEvent` — the Sui port of Solana Pay's `reference` pattern.
///      Indexer subscribes by `merchant_id` and resolves `order_ref → settled?`.
///
/// Caller PTB shape (constructed by the frontend):
///   auth    = account::new_auth(&ctx)
///   request = customer_acct_S.send_balance(&auth, &merchant_acct_S, amount, &ctx)
///   <stablecoin issuer's approve_transfer(request)>
///   payment::pay<S>(merchant, request, policy_s, customer_loyalty_account,
///                   order_ref, &clock, ctx)
///
/// If `customer_loyalty_account` does not exist yet (first-time customer), the
/// frontend prepends a PTB step `account::create_and_share(&mut namespace, customer)`
/// before this call.
module openzeppelin_payments::payment;

use openzeppelin_payments::loyalty;
use openzeppelin_payments::merchant::Merchant;
use pas::account::Account;
use pas::policy::Policy;
use pas::request::Request;
use pas::send_funds::{Self, SendFunds};
use sui::balance::Balance;
use sui::clock::Clock;
use sui::event;

#[error(code = 0)]
const EWrongRecipient: vector<u8> =
    b"Stablecoin payment recipient does not match merchant payout_address";
#[error(code = 1)]
const EWrongLoyaltyRecipient: vector<u8> =
    b"Loyalty account owner does not match stablecoin payer";

/// Indexer subscribes to this event filtered by `merchant_id`. `order_ref` is the
/// merchant's opaque order identifier (matches the QR-encoded reference).
public struct PaymentEvent has copy, drop {
    merchant_id: ID,
    order_ref: vector<u8>,
    customer: address,
    amount: u64,
    loyalty_minted: u64,
    timestamp_ms: u64,
}

public fun pay<S>(
    merchant: &mut Merchant,
    request: Request<SendFunds<Balance<S>>>,
    policy_s: &Policy<Balance<S>>,
    customer_loyalty_account: &Account,
    order_ref: vector<u8>,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    // Snapshot everything we need before any &mut borrow / consuming move.
    let merchant_id = object::id(merchant);
    let payout = merchant.payout_address();
    let (num, den, max) = merchant.mint_params();

    let payment_data = request.data();
    let customer_addr = payment_data.sender();
    let recipient_addr = payment_data.recipient();
    let payment_amount = payment_data.funds().value();

    // INV: stablecoin must be routed to this merchant.
    assert!(recipient_addr == payout, EWrongRecipient);

    // INV: loyalty mints to the payer's own loyalty account.
    assert!(customer_loyalty_account.owner() == customer_addr, EWrongLoyaltyRecipient);

    // Resolve send_funds — funds flow from customer's Account<S> into merchant's
    // payout Account<S>. Consumes the request.
    send_funds::resolve_balance(request, policy_s);

    // Compute mint amount in u128 to avoid overflow on payment_amount * num.
    let raw: u128 = (payment_amount as u128) * (num as u128) / (den as u128);
    let mint_amount: u64 = if (raw > (max as u128)) { max } else { (raw as u64) };

    // Mint and deposit (skip the call if zero — saves gas + an unneeded mint event).
    if (mint_amount > 0) {
        let cap = merchant.loyalty_treasury_cap_mut();
        loyalty::mint_into(cap, customer_loyalty_account, mint_amount);
    };

    event::emit(PaymentEvent {
        merchant_id,
        order_ref,
        customer: customer_addr,
        amount: payment_amount,
        loyalty_minted: mint_amount,
        timestamp_ms: clock.timestamp_ms(),
    });
}
