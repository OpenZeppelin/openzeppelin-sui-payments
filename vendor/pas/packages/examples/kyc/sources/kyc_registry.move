/// Example: KYC compliance with PAS.
///
/// Demonstrates a KYC registry where users must pass verification
/// before they can receive tokens.
module kyc::kyc_registry;

use kyc::my_coin::MY_COIN;
use pas::clawback_funds::ClawbackFunds;
use pas::request::Request;
use pas::send_funds::SendFunds;
use sui::balance::Balance;
use sui::vec_set::{Self, VecSet};

// ==== Error Codes ====

#[error(code = 0)]
const ENotKYCd: vector<u8> = b"Address has not passed KYC";

// ==== Structs ====

/// Witness stamp for approved transfers.
public struct TransferApproval() has drop;

/// Witness stamp for approved clawbacks (burn).
public struct ClawbackApproval() has drop;

/// On-chain KYC registry.
public struct KYCRegistry has key {
    id: UID,
    users: VecSet<address>,
}

/// Admin capability for managing the registry.
public struct RegistryCap has key, store { id: UID }

fun init(ctx: &mut TxContext) {
    transfer::share_object(KYCRegistry {
        id: object::new(ctx),
        users: vec_set::empty(),
    });
    transfer::transfer(RegistryCap { id: object::new(ctx) }, ctx.sender());
}

// ==== Public ====

/// Validates the recipient has passed KYC, then stamps the request.
public fun approve_transfer(
    registry: &KYCRegistry,
    request: &mut Request<SendFunds<Balance<MY_COIN>>>,
) {
    assert!(registry.users.contains(&request.data().recipient()), ENotKYCd);
    request.approve(TransferApproval());
}

/// Add a user to the KYC registry.
public fun add_user(registry: &mut KYCRegistry, _cap: &RegistryCap, user: address) {
    registry.users.insert(user);
}

/// Remove a user from the KYC registry.
public fun remove_user(registry: &mut KYCRegistry, _cap: &RegistryCap, user: address) {
    registry.users.remove(&user);
}

// ==== Package ====

/// Stamps the clawback request (no KYC check — issuer can always claw back).
public(package) fun approve_clawback(request: &mut Request<ClawbackFunds<Balance<MY_COIN>>>) {
    request.approve(ClawbackApproval());
}

/// Asserts user has passed KYC.
public(package) fun validate_mint(registry: &KYCRegistry, user: address) {
    assert!(registry.users.contains(&user), ENotKYCd);
}

/// Permit for TransferApproval (only this module can create it).
public(package) fun transfer_approval_permit(): internal::Permit<TransferApproval> {
    internal::permit()
}
