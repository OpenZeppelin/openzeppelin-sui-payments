/// Payment orchestration — generic over the PAS stablecoin type `S`.
///
/// - `pay<S>(&mut MerchantConfig, ...customer payment inputs..., order_ref, ...)` —
///   bundles the customer's PAS spend request and a loyalty mint request in one PTB.
///   The loyalty `MintCap` is borrowed from `MerchantConfig`; mint is rate-bounded by
///   the policy params stored there. Emits `PaymentEvent { merchant_config_id, order_ref,
///   customer, amount, loyalty_minted, timestamp_ms }`.
/// - Merchant verification: indexer subscribes to `PaymentEvent` filtered by
///   `merchant_config_id` and resolves `order_ref → settled?`. Sui port of Solana Pay's
///   `reference`, events-only (no on-chain PaymentIntent object).
/// - `withdraw_balance<S>(&MerchantCap, ...)` — thin wrapper over PAS transfer from the
///   merchant's payout-address PAS Account<S> to a designated address.
module openzeppelin_payments::payment;
