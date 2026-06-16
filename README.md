> [!Warning]
> This is experimental UN-AUDITED code currently under development

# openzeppelin-sui-payments

Closed-loop **stablecoin payments + loyalty + redemption** template for Sui, built on
the [Permissioned Asset Standard (PAS)](https://github.com/MystenLabs/pas) with role-based
access control from [openzeppelin/contracts-sui](https://github.com/OpenZeppelin/contracts-sui).

## Overview

A merchant deploys this template to accept stablecoin payments, automatically mint a
soulbound loyalty currency (`LOYALTY`) on each settlement, and let customers redeem that
loyalty for goods later — all on-chain, with PAS handling the balance/policy layer.

Two settlement flows, mirroring real-world POS. The `Merchant` shared object is the hub:
it stores open invoices, open vouchers, and settlement receipts in tables and owns both
flows.

- **Invoice → Pay** — merchant issues an invoice via `merchant::create_invoice` (cap-gated)
  carrying line items and the snapshotted loyalty reward; it's stored in the `Merchant` and
  surfaced by ID (off-chain QR). Customer scans, sends stablecoin via PAS through
  `merchant::pay`, earns LOYALTY balance, and a `Receipt` is recorded in the `Merchant`.
- **Voucher → Redeem** — customer locks LOYALTY balance in a voucher via
  `merchant::create_voucher` (stored in the `Merchant`, surfaced by ID for the QR);
  merchant scans + `merchant::redeem`s, the balance burns, and a `Receipt` is recorded.

Both invoices and vouchers carry the same `Item` type (variant_id + quantity + snapshot
unit_price), so the on-chain accounting is symmetric. Receipts use a generic `Receipt<T>`
with a flow-specific payload — `Receipt<Payment>` and `Receipt<Redemption>` — stored in the
`Merchant` in separate `invoice_receipts` / `voucher_receipts` tables keyed by the settling
invoice/voucher ID; per-customer history is served off-chain from the `InvoicePaid` /
`VoucherRedeemed` event stream.

Access control uses a single `AccessControl<MERCHANT>` registry with three operational
roles:

- **`MerchantRole`** — payout address, mint config, display name
- **`CatalogManagerRole`** — listings + variants CRUD + active toggle
- **`CashierRole`** — invoice issuance + voucher redemption

The deployer is the root holder and grants operational roles separately, so
cold-storage admin keys stay out of daily POS operations.

## Repository Layout

```text
contracts/
├── payments/         # The template (8 modules + 5 test files)
└── stablecoin-mock/  # Devnet-only mock PAS stablecoin (for end-to-end tests)
vendor/
└── pas/              # Vendored Permissioned Asset Standard
```

## Security

This project is maintained by OpenZeppelin with the goal of providing a secure and
reliable starter dApp for PoS systems built on top of the Sui ecosystem.

Refer to [SECURITY.md](SECURITY.md) for more details.
