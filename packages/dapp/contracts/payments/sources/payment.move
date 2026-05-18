/// Payment orchestration — generic over the PAS stablecoin type `S`.
///
/// - `pay<S>(...)` — bundles the customer's PAS spend request and a loyalty mint request
///   in one PTB. The loyalty `MintCap` is borrowed from `MerchantConfig`; the mint is
///   rate-bounded by the policy stored there.
/// - `PaymentIntent` — Sui port of Solana Pay's `reference` field. Created at QR-render
///   time (or referenced by order ID via event); merchant indexer watches it transition
///   to "paid" without polling by tx digest.
/// - `withdraw_balance<S>(...)` — merchant-gated stablecoin withdrawal.
module openzeppelin_payments::payment;
