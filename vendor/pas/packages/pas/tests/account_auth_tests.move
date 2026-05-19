#[test_only, allow(unused_variable, unused_mut_ref, dead_code)]
module pas::account_auth_tests;

use pas::{account::{Self, Account}, e2e::{test_tx, A}};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::return_shared;

#[test]
fun authenticate_with_uid() {
    test_tx!(@0x1, |namespace, managed_policy, _unmanaged_policy, scenario| {
        let namespace_id = object::id(namespace);
        scenario.next_tx(@0x1);

        // create a UID.
        let mut uid = object::new(scenario.ctx());

        let uid_address = uid.to_inner().to_address();
        account::create_and_share(namespace, uid_address);

        scenario.next_tx(@0x1);

        let mut account = scenario.take_shared<Account>();

        assert_eq!(account.owner(), uid_address);
        assert_eq!(object::id(&account).to_address(), namespace.account_address(uid_address));

        let auth = account::new_auth_as_object(&mut uid);

        let transfer_request = account.unsafe_send_balance<A>(
            &auth,
            @0x2,
            50,
            scenario.ctx(),
        );

        assert_eq!(transfer_request.data().sender(), uid_address);
        assert_eq!(transfer_request.data().recipient(), @0x2);
        assert_eq!(
            transfer_request.data().sender_account_id(),
            namespace.account_address(uid_address).to_id(),
        );
        assert_eq!(
            transfer_request.data().recipient_account_id(),
            namespace.account_address(@0x2).to_id(),
        );
        assert_eq!(transfer_request.data().funds().value(), 50);

        destroy(transfer_request);

        return_shared(account);
        uid.delete();
    });
}

#[test, expected_failure(abort_code = ::pas::account::ENotOwner)]
fun try_to_auth_to_another_owners_account() {
    test_tx!(@0x1, |namespace, managed_policy, _unmanaged_policy, scenario| {
        scenario.next_tx(@0x1);
        account::create_and_share(namespace, @0x1);

        scenario.next_tx(@0x2);

        let mut account = scenario.take_shared_by_id<Account>(namespace
            .account_address(
                @0x1,
            )
            .to_id());

        let auth = account::new_auth(scenario.ctx());

        let _transfer_request = account.unsafe_send_balance<A>(
            &auth,
            @0x2,
            50,
            scenario.ctx(),
        );

        abort
    });
}

#[test, expected_failure(abort_code = ::pas::account::ENotOwner)]
fun try_to_auth_to_another_uid_account() {
    test_tx!(@0x1, |namespace, managed_policy, _unmanaged_policy, scenario| {
        scenario.next_tx(@0x1);
        let mut account = account::create(namespace, @0x1);

        let mut uid = object::new(scenario.ctx());

        let auth = account::new_auth_as_object(&mut uid);

        let transfer_request = account.unlock_balance<A>(
            &auth,
            50,
            scenario.ctx(),
        );

        abort
    });
}

#[test, expected_failure(abort_code = ::pas::account::EAccountAlreadyExists)]
fun try_to_create_account_with_same_owner() {
    test_tx!(@0x1, |namespace, managed_policy, _unmanaged_policy, scenario| {
        scenario.next_tx(@0x1);
        account::create_and_share(namespace, @0x1);
        account::create_and_share(namespace, @0x1);
        abort
    });
}
