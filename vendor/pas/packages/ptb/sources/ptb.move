/// Module: ptb
module ptb::ptb;

use std::bcs;
use std::string::String;
use std::type_name;

const OBJECT_BY_ID_EXT: vector<u8> = b"object_by_id:";
const OBJECT_BY_TYPE_EXT: vector<u8> = b"object_by_type:";
const RECEIVING_BY_ID_EXT: vector<u8> = b"receiving_by_id:";

/// Tag for extended arguments. Intentionally offset to not be mistaken for a
/// command tag.
const EXT_TAG: u8 = 100;

/// Defines a PTB template. Unlike the canonical Sui PTB, this one does not have inputs.
/// Instead, the inputs are passed in as arguments to the commands directly. And
/// while this is a bit more verbose and less optimized storage wise, it is more
/// flexible format for off-chain handling.
public struct Transaction has copy, drop, store {
    commands: vector<Command>,
}

/// Defines a simplified `Argument` type for the `Transaction`.
public enum Argument has copy, drop, store {
    GasCoin,
    Input(CallArg), // thing about using CallArg here
    Result(u16),
    NestedResult(u16, u16),
    /// Extended arguments for off-chain resolution.
    /// Cannot be constructed directly, only through future extensions.
    Ext(vector<u8>),
}

/// A command is a struct representation of an enum.
/// This way the type layout is decreased and not facing execution / vm limits.
///
/// Enum tags in order:
/// - MoveCall: 0
/// - TransferObjects: 1
/// - SplitCoins: 2
/// - MergeCoins: 3
/// - Publish: 4
/// - MakeMoveVec: 5
/// - Upgrade: 6
/// - Ext: 7
public struct Command(u8, vector<u8>) has copy, drop, store;

/// A command for a Move call.
/// Tag: 0
public struct MoveCall has copy, drop, store {
    package_id: String,
    module_name: String,
    function: String,
    arguments: vector<Argument>,
    type_arguments: vector<String>,
}

/// A command for transferring objects.
/// Tag: 1
public struct TransferObjects has copy, drop, store {
    objects: vector<Argument>,
    to: Argument,
}

/// A command for splitting coins.
/// Tag: 2
public struct SplitCoins has copy, drop, store {
    coin: Argument,
    amounts: vector<Argument>,
}

/// A command for merging coins.
/// Tag: 3
public struct MergeCoins has copy, drop, store {
    coin: Argument,
    coins: vector<Argument>,
}

/// A command for publishing a package.
/// Tag: 4
public struct Publish has copy, drop, store {
    modules_bytes: vector<vector<u8>>,
    dependencies: vector<ID>,
}

/// A command for making a Move vector.
/// Tag: 5
public struct MakeMoveVec has copy, drop, store {
    element_type: Option<String>,
    elements: vector<Argument>,
}

/// A command for upgrading a package.
/// Tag: 6
public struct Upgrade has copy, drop, store {
    modules_bytes: vector<vector<u8>>,
    dependencies: vector<ID>,
    object_id: ID,
    upgrade_ticket: Argument,
}

/// Defines a simplified `CallArg` type for `Transaction`.
///
/// Differences with canonical Sui `CallArg` type:
/// - ObjectArg is a simplified, unresolved representation of Object arguments;
/// - Ext(...) is a custom extension for the `CallArg` which allows off-chain
///   resolvers to convert them into the appropriate values for context.
public enum CallArg has copy, drop, store {
    Pure(vector<u8>),
    Object(ObjectArg),
    FundsWithdrawal {
        amount: u64,
        type_name: String,
        withdraw_from: WithdrawFrom,
    },
    /// Extended arguments for off-chain resolution.
    /// Can be created and registered in a transaction through `ext_input`.
    ///
    /// Extended arguments are namespaced by Type associated with them. In an
    /// application, this can be the root object, or a special type used for off
    /// chain resolution.
    Ext(String, String),
}

/// Defines a simplified `ObjectArg` type for the `Transaction`.
///
/// Differences with canonical Sui `ObjectArg` type:
/// - Uses `address` type as a fixed-length sequence of bytes without length prefix.
/// - Extends the number of variants to support off-chain resolution.
public enum ObjectArg has copy, drop, store {
    ImmOrOwnedObject {
        object_id: ID,
        sequence_number: u64,
        digest: address,
    },
    SharedObject {
        object_id: ID,
        initial_shared_version: u64,
        is_mutable: bool,
    },
    Receiving {
        object_id: ID,
        sequence_number: u64,
        digest: address,
    },
    Ext(String),
}

public enum WithdrawFrom has copy, drop, store {
    Sender,
    Sponsor,
}

/// Create a new Transaction builder.
public fun new(): Transaction {
    Transaction { commands: vector[] }
}

// === System Objects ===

/// Shorthand for `object_by_id` with `0x6` (Clock).
public fun clock(): Argument { object_by_id(@0x6.to_id()) }

/// Shorthand for `object_by_id` with `0x8` (Random).
public fun random(): Argument { object_by_id(@0x8.to_id()) }

/// Shorthand for `object_by_id` with `0xD` (DisplayRegistry).
public fun display(): Argument { object_by_id(@0xD.to_id()) }

/// Shorthand for `object_by_id` with `0x403` (DenyList).
public fun deny_list(): Argument { object_by_id(@0x403.to_id()) }

/// Shorthand for `object_by_id` with `0xC` (CoinRegistry).
public fun coin_registry(): Argument { object_by_id(@0xC.to_id()) }

/// Shorthand for `object_by_id` with `0xACC` (AccumulatorRoot).
public fun accumulator_root(): Argument { object_by_id(@0xacc.to_id()) }

// === Inputs ===

/// Create a gas coin input.
public fun gas(): Argument {
    Argument::GasCoin
}

/// Create a pure input.
public fun pure<T: drop>(value: T): Argument {
    Argument::Input(CallArg::Pure(bcs::to_bytes(&value)))
}

/// Create a fully-resolved immutable or owned object argument.
/// Should be used with caution, yet for immutable or owned objects refs can be stored.
/// For automatic version resolution, use `object_by_id`.
public fun object_ref(object_id: ID, sequence_number: u64, digest: address): Argument {
    Argument::Input(
        CallArg::Object(ObjectArg::ImmOrOwnedObject {
            object_id,
            sequence_number,
            digest,
        }),
    )
}

/// Create a fully-resolved shared object argument.
/// Should be used with caution, yet for shared objects refs can be stored.
/// For automatic version resolution, use `shared_object_by_id`.
///
/// TODO: should it be named `consensus_managed_object_ref`?
/// NOTE: the naming is changing elsewhere
public fun shared_object_ref(
    object_id: ID,
    initial_shared_version: u64,
    is_mutable: bool,
): Argument {
    Argument::Input(
        CallArg::Object(ObjectArg::SharedObject {
            object_id,
            initial_shared_version,
            is_mutable,
        }),
    )
}

/// Create a fully-resolved receiving object argument.
/// Should be used with caution, since the version of the object is dynamic. For
/// automatic version resolution, use `object_by_id`.
public fun receiving_object_ref(object_id: ID, sequence_number: u64, digest: address): Argument {
    Argument::Input(
        CallArg::Object(ObjectArg::Receiving {
            object_id,
            sequence_number,
            digest,
        }),
    )
}

// === Extended Object Args ===

/// Create an off-chain input handler for a given type T.
public fun object_by_type<T: key>(): Argument {
    let mut base_ext = OBJECT_BY_TYPE_EXT.to_string();
    base_ext.append((*type_name::with_defining_ids<T>().as_string()).to_string());
    Argument::Input(CallArg::Object(ObjectArg::Ext(base_ext)))
}

/// Create an off-chain input handler for a given type as a String.
public fun object_by_type_string(type_name: String): Argument {
    let mut base_ext = OBJECT_BY_TYPE_EXT.to_string();
    base_ext.append(type_name);
    Argument::Input(CallArg::Object(ObjectArg::Ext(base_ext)))
}

/// Create an off-chain input handler for an object with a specific ID.
public fun object_by_id(id: ID): Argument {
    let mut base_ext = OBJECT_BY_ID_EXT.to_string();
    base_ext.append(id.to_address().to_string());
    Argument::Input(CallArg::Object(ObjectArg::Ext(base_ext)))
}

/// Create an off-chain input handler for a receiving object with a specific ID.
public fun receiving_object_by_id(id: ID): Argument {
    let mut base_ext = RECEIVING_BY_ID_EXT.to_string();
    base_ext.append(id.to_address().to_string());
    Argument::Input(CallArg::Object(ObjectArg::Ext(base_ext)))
}

/// Create an external input handler.
/// Expected to be understood by the off-chain tooling.
public fun ext_input<T>(name: String): Argument {
    Argument::Input(
        CallArg::Ext((*type_name::with_original_ids<T>().as_string()).to_string(), name),
    )
}

/// Create an external input handler for a given type T.
/// This can be used to hardcode the namespace value without having access to `T`.
public fun ext_input_raw(namespace: String, name: String): Argument {
    Argument::Input(CallArg::Ext(namespace, name))
}

/// Register a command in the Transaction builder. Returns the Argument, which
/// is treated as the `Result(idx)` of the command, and can be turned into a nested
/// result `NestedResult(idx, idx)`.
public fun command(self: &mut Transaction, command: Command): Argument {
    let idx = self.commands.length() as u16;
    self.commands.push_back(command);
    Argument::Result(idx)
}

/// Spawn a nested result out of a (just) `Result`.
/// Simple result is a command output.
public fun nested(self: &Argument, sub_idx: u16): Argument {
    match (self) {
        Argument::Result(idx) => Argument::NestedResult(*idx, sub_idx),
        _ => abort,
    }
}

// === Commands ===

/// Create a `MoveCall` command.
public fun move_call(
    package_id: String,
    module_name: String,
    function: String,
    arguments: vector<Argument>,
    type_arguments: vector<String>,
): Command {
    Command(
        0,
        bcs::to_bytes(
            &MoveCall {
                package_id,
                module_name,
                function,
                arguments,
                type_arguments,
            },
        ),
    )
}

/// Create a `TransferObjects` command
/// Expects a vector of arguments to transfer and an address value for destination.
public fun transfer_objects(objects: vector<Argument>, to: Argument): Command {
    Command(1, bcs::to_bytes(&TransferObjects { objects, to }))
}

/// Create a `SplitCoins` command.
public fun split_coins(coin: Argument, amounts: vector<Argument>): Command {
    Command(2, bcs::to_bytes(&SplitCoins { coin, amounts }))
}

/// Create a `MergeCoins` command.
/// Takes a Coin Argument and a vector of other coin arguments to merge into it.
public fun merge_coins(coin: Argument, coins: vector<Argument>): Command {
    Command(3, bcs::to_bytes(&MergeCoins { coin, coins }))
}

/// Create a `Publish` command.
/// Takes a vector of modules' bytes and a vector of dependencies.
public fun publish(modules_bytes: vector<vector<u8>>, dependencies: vector<ID>): Command {
    Command(4, bcs::to_bytes(&Publish { modules_bytes, dependencies }))
}

/// Create a `MakeMoveVec` command.
/// Takes an optional element type and a vector of elements to make into a vector.
public fun make_move_vec(element_type: Option<String>, elements: vector<Argument>): Command {
    Command(5, bcs::to_bytes(&MakeMoveVec { element_type, elements }))
}

/// Create a `Upgrade` command.
/// Takes a vector of modules' bytes, a vector of dependencies, an updated package
/// ID, and an upgrade ticket.
public fun upgrade(
    modules_bytes: vector<vector<u8>>,
    dependencies: vector<ID>,
    object_id: ID,
    upgrade_ticket: Argument,
): Command {
    Command(6, bcs::to_bytes(&Upgrade { modules_bytes, dependencies, object_id, upgrade_ticket }))
}

/// Create an `Ext` command.
public fun ext(data: vector<u8>): Command {
    Command(EXT_TAG, data)
}

// === Test Features ===

#[test_only]
public use fun argument_idx as Argument.idx;

#[test_only]
public fun argument_idx(self: &Argument): u16 {
    match (self) {
        Argument::Result(idx) => *idx,
        Argument::NestedResult(idx, _) => *idx,
        // Argument::Input(idx) => *idx,
        _ => abort,
    }
}
