/// Template stores all the Command templates for PAS.
///
/// This is the lookup point for PTB resolution on the client-side!
/// There's no versioning enforcement here, as this is purely an off-chain used endpoint.
module pas::templates;

use pas::{keys, namespace::Namespace};
use ptb::ptb::Command;
use std::type_name;
use sui::{derived_object, dynamic_field};

#[error(code = 0)]
const ETemplateNotSet: vector<u8> = b"Template not set for this action.";

/// Namespacing type for `ext_input`'s.
public struct PAS {}

public struct Templates has key {
    id: UID,
}

/// Create the templates registry
entry fun setup(namespace: &mut Namespace) {
    transfer::share_object(Templates {
        id: derived_object::claim(namespace.uid_mut(), keys::template_key()),
    })
}

/// Sets the PTB template for a given Action.
public fun set_template_command<A: drop>(
    templates: &mut Templates,
    _: internal::Permit<A>,
    command: Command,
) {
    let key = type_name::with_defining_ids<A>();
    if (dynamic_field::exists_(&templates.id, key)) {
        let _ = dynamic_field::remove<_, Command>(&mut templates.id, key);
    };

    dynamic_field::add(&mut templates.id, key, command);
}

public fun unset_template_command<A: drop>(templates: &mut Templates, _: internal::Permit<A>) {
    let key = type_name::with_defining_ids<A>();
    assert!(dynamic_field::exists_(&templates.id, key), ETemplateNotSet);
    dynamic_field::remove<_, Command>(&mut templates.id, key);
}
