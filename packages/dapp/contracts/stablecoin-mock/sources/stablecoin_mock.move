/// Mock stablecoin for dev/testnet — a plain Sui `Coin<STABLECOIN_MOCK>` with a
/// permissionless faucet entry. Use only on devnet/testnet; production deployments
/// instantiate `payment::pay<S>` with a real stablecoin Coin type (e.g. Circle USDC).
///
/// Why plain `Coin` and not PAS: see the design note in `openzeppelin_payments::payment`.
/// The `payments` package is generic over `S`, so swapping this mock for a real
/// stablecoin needs no Move-side changes — only a redeploy with the new `S`.
module local_mock_stablecoin::stablecoin_mock;

use sui::coin::{Self, TreasuryCap};
use sui::coin_registry;

/// One-time witness.
public struct STABLECOIN_MOCK has drop {}

/// Module init creates the currency, freezes its metadata, and shares the
/// `TreasuryCap` so the faucet is permissionlessly callable. Devnet only.
fun init(otw: STABLECOIN_MOCK, ctx: &mut TxContext) {
    let (initializer, cap) = coin_registry::new_currency_with_otw(
        otw,
        6,
        b"MOCKUSD".to_string(),
        b"Mock USD".to_string(),
        b"Mock stablecoin for OpenZeppelin Sui Payments template (devnet only).".to_string(),
        b"".to_string(),
        ctx,
    );
    let metadata = initializer.finalize(ctx);
    transfer::public_freeze_object(metadata);
    transfer::public_share_object(cap);
}

/// Permissionless faucet. Mints `amount` mock USD to the caller. Devnet only — there is
/// nothing stopping a real merchant fork from removing this and using a different
/// stablecoin.
#[allow(lint(self_transfer))]
public fun faucet(cap: &mut TreasuryCap<STABLECOIN_MOCK>, amount: u64, ctx: &mut TxContext) {
    let coin = coin::mint(cap, amount, ctx);
    transfer::public_transfer(coin, ctx.sender());
}
