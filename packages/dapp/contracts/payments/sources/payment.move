/// Payment orchestration — generic over the PAS stablecoin type `S`.
///
/// - `pay<S>(&mut Merchant, ...customer payment inputs..., order_ref, ...)` —
///   bundles the customer's PAS spend request and a loyalty mint request in one PTB.
///   The loyalty `TreasuryCap` is borrowed from `Merchant`; mint amount is computed via
///   the merchant's stored ratio and bounded by `max_mint_per_payment`. Emits
///   `PaymentEvent { merchant_id, order_ref, customer, amount, loyalty_minted, timestamp_ms }`.
/// - Merchant verification: indexer subscribes to `PaymentEvent` filtered by `merchant_id`
///   and resolves `order_ref → settled?`. Sui port of Solana Pay's `reference`, events-only
///   (no on-chain PaymentIntent object).
/// - `withdraw_balance<S>(&MerchantCap, ...)` — thin wrapper over PAS transfer from the
///   merchant's payout-address PAS Account<S> to a designated address.
module openzeppelin_payments::payment;
