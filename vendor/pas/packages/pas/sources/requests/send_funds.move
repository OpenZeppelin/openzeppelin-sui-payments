module pas::send_funds;

use pas::{keys::send_funds_action, policy::Policy, request::{Self, Request}};
use sui::balance::{Self, Balance};

/// A transfer request that is generated once a send funds request is initialized.
///
/// A hot potato that is issued when a transfer is initiated.
/// It can only be resolved by presenting a witness `U` that is the witness of `Policy<T>`
///
/// This enables the `resolve` function of each smart contract to
/// be flexible and implement its own mechanisms for validation.
/// The individual resolution module can:
///   - Check whitelists/blacklists
///   - Enforce holding periods
///   - Collect fees
///   - Emit regulatory events
///   - Handle dividends/distributions
///   - Implement any jurisdiction-specific rules
public struct SendFunds<T: store> {
    /// `sender` is the wallet OR object address, NOT the account address
    sender: address,
    /// `recipient` is the wallet OR object address, NOT the account address
    recipient: address,
    /// The ID of the account the funds are coming from
    sender_account_id: ID,
    /// The ID of the account the funds are going to
    recipient_account_id: ID,
    /// The balance being transferred
    funds: T,
}

public fun sender<T: store>(request: &SendFunds<T>): address { request.sender }

public fun recipient<T: store>(request: &SendFunds<T>): address { request.recipient }

public fun sender_account_id<T: store>(request: &SendFunds<T>): ID { request.sender_account_id }

public fun recipient_account_id<T: store>(request: &SendFunds<T>): ID {
    request.recipient_account_id
}

public fun funds<T: store>(request: &SendFunds<T>): &T { &request.funds }

public(package) fun new<T: store>(
    sender: address,
    recipient: address,
    sender_account_id: ID,
    recipient_account_id: ID,
    funds: T,
): Request<SendFunds<T>> {
    request::new(SendFunds {
        sender,
        recipient,
        sender_account_id,
        recipient_account_id,
        funds,
    })
}

/// resolve a transfer request, if funds management is enabled & there are enough approvals.
public fun resolve_balance<C>(
    request: Request<SendFunds<Balance<C>>>,
    policy: &Policy<Balance<C>>,
) {
    policy.versioning().assert_is_valid_version();
    let data = request.resolve(policy.required_approvals(send_funds_action()));

    let SendFunds { funds, recipient_account_id, .. } = data;
    balance::send_funds(funds, recipient_account_id.to_address());
}
