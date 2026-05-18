/// Product catalog CRUD.
///
/// Holds items (name + size + price) keyed under a `Catalog` object owned by the merchant
/// instance. All write entries (`add_item`, `update_item`, `remove_item`) are gated by
/// `&MerchantCap`.
module openzeppelin_payments::catalog;
