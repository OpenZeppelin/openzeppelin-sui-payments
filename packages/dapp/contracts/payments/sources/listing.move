/// Listing data type and CRUD operations.
///
/// Defines `Listing` (one menu line: name + price + active flag), stored as entries in
/// `MerchantConfig.listings: Table<u64, Listing>`. CRUD entries (`add`, `update`, `remove`,
/// `set_active`) take `&mut MerchantConfig` plus `&MerchantCap` and operate on the table.
///
/// Modeled after `openzeppelin-sui-marketplace::oracle-market::listing` — one listing per
/// purchasable line. Variant-bearing products (e.g. Latte S/M/L) become three listings.
module openzeppelin_payments::listing;
