/// Merchant identity and configuration.
///
/// Defines:
/// - `MerchantConfig` — shared object holding wrapped PAS `MintCap` for the loyalty asset
///   plus rate-bound mint policy params. Referenced by `payment` and `redemption`.
/// - `MerchantCap` — owned capability passed by reference to gate merchant-only entries
///   across `catalog`, `payment::withdraw_balance`, and `redemption::verify`.
///
/// Module init creates both objects at deploy and transfers `MerchantCap` to the publisher.
module openzeppelin_payments::merchant;
