/// Payment orchestration — generic over the stablecoin type `S` (a plain Sui `Coin<S>`,
/// e.g. real USDC or the template's mock).
///
/// `pay<S>` is the single atomic entry that:
///   1. Routes the customer's `Coin<S>` to `merchant.payout_address` via standard Sui
///      transfer.
///   2. Mints loyalty into the customer's `Account<LOYALTY>` at the merchant's stored
///      rate, bounded by `max_mint_per_payment`.
///   3. Emits `PaymentEvent` — the Sui port of Solana Pay's `reference` pattern.
///      Indexer subscribes by `merchant_id` and resolves `order_ref → settled?`.
///
/// Caller PTB shape (constructed by the frontend):
///   coin = <split off exact amount from customer's Coin<S>>
///   payment::pay<S>(merchant, coin, customer_loyalty_account, order_ref, &clock, ctx)
///
/// If `customer_loyalty_account` does not exist yet (first-time customer), the frontend
/// prepends `account::create_and_share(&mut namespace, customer)` to the PTB. The
/// stablecoin side is a plain Sui Coin transfer — no PAS Account / Policy / approval
/// machinery is required from the stablecoin issuer.
///
/// Design note: the stablecoin uses plain `Coin<S>` rather than a PAS asset because
/// production stablecoins on Sui (e.g. Circle USDC) are `Coin`-based and we don't want
/// to gate the template on issuer-side PAS adoption. The loyalty asset stays on PAS for
/// soulbound enforcement (`loyalty.move`). Forks needing issuer-controlled stablecoin
/// compliance hooks can add a PAS wrapper back to this function.
module openzeppelin_payments::payment;

use openzeppelin_payments::loyalty;
use openzeppelin_payments::merchant::Merchant;
use pas::account::Account;
use sui::clock::Clock;
use sui::coin::Coin;
use sui::event;

#[error(code = 0)]
const EWrongLoyaltyRecipient: vector<u8> =
    b"Loyalty account owner does not match payer";

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
    coin: Coin<S>,
    customer_loyalty_account: &Account,
    order_ref: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let merchant_id = object::id(merchant);
    let payout = merchant.payout_address();
    let (num, den, max) = merchant.mint_params();

    let customer_addr = ctx.sender();
    let payment_amount = coin.value();

    // INV: loyalty mints to the payer's own loyalty account.
    assert!(customer_loyalty_account.owner() == customer_addr, EWrongLoyaltyRecipient);

    // Route the stablecoin to the merchant. Plain Sui transfer — payout is an
    // address-owned Coin<S> in the merchant's wallet, which they can drain or merge as
    // they please.
    transfer::public_transfer(coin, payout);

    // u128 intermediate to dodge overflow when payment_amount * num exceeds u64.
    let raw: u128 = (payment_amount as u128) * (num as u128) / (den as u128);
    let mint_amount: u64 = if (raw > (max as u128)) { max } else { (raw as u64) };

    // Skip the call if zero — saves gas and lets the merchant disable loyalty by
    // setting num = 0 without breaking payments.
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
