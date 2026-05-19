#[mode(test)]
module ptb::ptb_tests;

use ptb::ptb;
use std::type_name;
use std::unit_test::assert_eq;
use sui::kiosk::Kiosk;

/// Keeping this for testing purposes.
public struct PAS {}

/// NFT type for kiosk example.
public struct NFT has key, store { id: UID }

#[test]
fun ptb() {
    let mut ptb = ptb::new();
    let clock = ptb::clock();
    let arg = ptb.command(
        ptb::move_call(
            @0x2.to_string(),
            "clock",
            "timestamp_ms",
            vector[clock],
            vector[],
        ),
    );

    // split twice
    let coins = ptb.command(ptb::split_coins(ptb::gas(), vector[arg, arg]));

    ptb.command(ptb::transfer_objects(vector[coins.nested(0), coins.nested(1)], ptb::pure(@0)));

    assert_eq!(arg.idx(), 0);
}

#[test]
fun simple_option_and_vec_operations() {
    let mut ptb = ptb::new();

    let some_arg = ptb.command(
        ptb::move_call(
            @0x1.to_string(),
            "option",
            "some",
            vector[ptb::pure(100u64)],
            vector["u64"],
        ),
    );

    // dummy bool result
    let _ = ptb.command(
        ptb::move_call(
            @0x1.to_string(),
            "option",
            "is_some",
            vector[some_arg],
            vector["u64"],
        ),
    );

    let u64_val = ptb.command(
        ptb::move_call(
            @0x1.to_string(),
            "option",
            "swap",
            vector[some_arg, ptb::pure(200u64)],
            vector["u64"],
        ),
    );

    let vec = ptb.command(
        ptb::make_move_vec(option::some("u64"), vector[u64_val, ptb::pure(300u64)]),
    );

    2u8.do!(
        |_| ptb.command(
            ptb::move_call(
                @0x1.to_string(),
                "vector",
                "pop_back",
                vector[vec],
                vector["u64"],
            ),
        ),
    );

    // lastly, destroy empty vector
    ptb.command(
        ptb::move_call(
            @0x1.to_string(),
            "vector",
            "destroy_empty",
            vector[vec],
            vector["u64"],
        ),
    );
}

#[test]
fun pas_command_with_ext_inputs() {
    ptb::move_call(
        @0x0.to_string(),
        "demo_usd",
        "resolve_transfer",
        vector[ptb::ext_input<PAS>("request"), ptb::ext_input<PAS>("policy_arg"), ptb::clock()],
        vector["magic::usdc_app::DEMO_USDC"],
    );
}

#[test]
fun kiosk_transaction_with_rules_resolution() {
    let mut ptb = ptb::new();
    let nft_type = (*type_name::with_original_ids<NFT>().as_string()).to_string();

    let paid = ptb.command(
        ptb::move_call(
            @0x2.to_string(),
            "transfer_policy",
            "paid",
            vector[ptb::ext_input<Kiosk>("request")],
            vector[nft_type],
        ),
    );

    let fee_amount = ptb.command(
        ptb::move_call(
            "@mysten/kiosk",
            "royalty_rule",
            "fee_amount",
            vector[ptb::ext_input<Kiosk>("policy"), paid],
            vector[nft_type],
        ),
    );

    let royalty_payment = ptb.command(ptb::split_coins(ptb::gas(), vector[fee_amount]));

    // pay royalty
    ptb.command(
        ptb::move_call(
            "@mysten/kiosk",
            "royalty_rule",
            "pay",
            vector[
                ptb::ext_input<Kiosk>("policy"),
                ptb::ext_input<Kiosk>("request"),
                royalty_payment,
            ],
            vector[nft_type],
        ),
    );

    // lock item in the buyer kiosk
    ptb.command(
        ptb::move_call(
            @0x2.to_string(),
            "kiosk",
            "lock",
            vector[ptb::ext_input<Kiosk>("buyer_kiosk"), ptb::ext_input<Kiosk>("item")],
            vector[nft_type],
        ),
    );

    // prove that the item is locked
    ptb.command(
        ptb::move_call(
            "@mysten/kiosk",
            "kiosk_lock_rule",
            "prove",
            vector[ptb::ext_input<Kiosk>("request"), ptb::ext_input<Kiosk>("buyer_kiosk")],
            vector[nft_type],
        ),
    );

    // confirm the request
    ptb.command(
        ptb::move_call(
            @0x2.to_string(),
            "transfer_policy",
            "confirm_request",
            vector[ptb::ext_input<Kiosk>("policy"), ptb::ext_input<Kiosk>("request")],
            vector[nft_type],
        ),
    );
}
