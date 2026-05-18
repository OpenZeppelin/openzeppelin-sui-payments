/// Soulbound PAS loyalty asset.
///
/// One-time-witness pattern publishes `LOYALTY` as a PAS-issued fungible asset with a
/// transfer rule that always rejects (the soulbound mechanic). Mint is `public(package)`
/// and only callable by `payment` (earning) and `redemption` (burn-on-verify).
///
/// The `MintCap` is created at module init and immediately wrapped into `MerchantConfig`
/// (see `merchant`) — never held by an EOA. Mint requests are rate-bounded by the policy
/// stored on `MerchantConfig`.
module openzeppelin_payments::loyalty;
