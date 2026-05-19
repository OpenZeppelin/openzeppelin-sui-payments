/// MY_COIN currency type definition and creation.
module kyc::my_coin;

use sui::coin_registry;

public struct MY_COIN has drop {}

fun init(otw: MY_COIN, ctx: &mut TxContext) {
    let (initializer, cap) = coin_registry::new_currency_with_otw(
        otw,
        6,
        b"MYC".to_string(),
        b"My Coin".to_string(),
        b"Example regulated coin with KYC compliance".to_string(),
        b"https://example.com".to_string(),
        ctx,
    );
    let metadata = initializer.finalize(ctx);

    transfer::public_transfer(cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}
