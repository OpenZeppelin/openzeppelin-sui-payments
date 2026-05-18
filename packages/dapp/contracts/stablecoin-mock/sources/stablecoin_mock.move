/// Mock PAS-issued stablecoin for dev/testnet.
///
/// Provides a single PAS asset type `MOCK_USD` that `openzeppelin_payments::payment` can
/// instantiate `S` to during local dev and CI. Drops a permissionless faucet entry so
/// the template's onboarding flow works end-to-end without an external issuer.
///
/// Production deployments swap this package for a real PAS-issued stablecoin; the
/// `payments` package is generic over `S` so no Move-side changes are required.
module local_mock_stablecoin::stablecoin_mock;
