module pas::keys;

use std::string::String;
use sui::vec_set::{Self, VecSet};

/// Key for deriving `Policy<T>` from the namespace
public struct PolicyKey<phantom T>() has copy, drop, store;

/// Key for deriving `Account` from the namespace
public struct AccountKey(address) has copy, drop, store;

/// Key for deriving `Templates` from the namespace
public struct TemplateKey() has copy, drop, store;

/// WARNING: these should only be used internally.
public(package) fun policy_key<T>(): PolicyKey<T> { PolicyKey<T>() }

public(package) fun account_key(owner: address): AccountKey { AccountKey(owner) }

public(package) fun template_key(): TemplateKey { TemplateKey() }

const SEND_FUNDS_ACTION_TYPE: vector<u8> = b"send_funds";
const UNLOCK_FUNDS_ACTION_TYPE: vector<u8> = b"unlock_funds";
const CLAWBACK_FUNDS_ACTION_TYPE: vector<u8> = b"clawback_funds";

public fun send_funds_action(): String { SEND_FUNDS_ACTION_TYPE.to_string() }

public fun unlock_funds_action(): String { UNLOCK_FUNDS_ACTION_TYPE.to_string() }

public fun clawback_funds_action(): String { CLAWBACK_FUNDS_ACTION_TYPE.to_string() }

public fun actions(): VecSet<String> {
    vec_set::from_keys(vector[
        SEND_FUNDS_ACTION_TYPE.to_string(),
        UNLOCK_FUNDS_ACTION_TYPE.to_string(),
        CLAWBACK_FUNDS_ACTION_TYPE.to_string(),
    ])
}

public fun is_valid_action(action: String): bool {
    actions().contains(&action)
}
