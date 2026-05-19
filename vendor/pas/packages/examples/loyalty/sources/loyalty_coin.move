/// LOYALTY_COIN currency type definition and creation.
module loyalty::loyalty_coin;

use sui::coin_registry;

public struct LOYALTY_COIN has drop {}

fun init(otw: LOYALTY_COIN, ctx: &mut TxContext) {
    let (initializer, cap) = coin_registry::new_currency_with_otw(
        otw,
        6,
        b"LYL".to_string(),
        b"Loyalty Points".to_string(),
        b"Example loyalty points demonstrating unlock behavior".to_string(),
        b"https://example.com".to_string(),
        ctx,
    );
    let metadata = initializer.finalize(ctx);

    transfer::public_transfer(cap, ctx.sender());
    transfer::public_transfer(metadata, ctx.sender());
}
