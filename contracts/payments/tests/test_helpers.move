/// Shared test-only helpers for `openzeppelin_payments` tests.
#[test_only]
module openzeppelin_payments::test_helpers;

/// Assert that an event of type `$T` equal to `$expected` was emitted in the
/// current transaction. Compares full field values (not just that *some* event of
/// the type fired). Mirrors the OpenZeppelin Sui AMM `assert_emitted` helper.
public(package) macro fun assert_emitted<$T>($expected: $T) {
    let expected = $expected;
    let events = sui::event::events_by_type<$T>();
    if (events.length() == 0) {
        std::debug::print(&b"Assertion failed. No events emitted.".to_string());
        abort
    };
    let emitted = events.any!(|event| event == expected);
    if (!emitted) {
        std::debug::print(&b"Assertion failed. Different events emitted:".to_string());
        std::debug::print(&events);
        std::debug::print(&b"No matching event".to_string());
        abort
    };
}
