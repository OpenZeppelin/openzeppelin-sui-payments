# openzeppelin-sui-payments

Closed-loop **stablecoin payments + loyalty + redemption** template for Sui, built on
the [Permissioned Asset Standard (PAS)](https://github.com/MystenLabs/pas) with role-based
access control from [openzeppelin/contracts-sui](https://github.com/OpenZeppelin/contracts-sui).

## Overview

A merchant deploys this template to accept stablecoin payments, automatically mint a
soulbound loyalty currency (`LOYALTY`) on each settlement, and let customers redeem that
loyalty for goods later — all on-chain, with PAS handling the balance/policy layer.

Two settlement flows, mirroring real-world POS:

- **Invoice → Pay** — merchant issues an `Invoice` (cap-gated) carrying line items and
  the snapshotted loyalty reward. Customer scans, sends stablecoin via PAS, gets a
  soulbound `Receipt<Payment>` and earns LOYALTY balance.
- **Voucher → Redeem** — customer locks LOYALTY balance in a `Voucher` (off-chain QR),
  merchant scans + redeems, balance burns and customer gets a `Receipt<Redemption>`.

Both invoices and vouchers carry the same `Item` type (variant_id + quantity + snapshot
unit_price), so the on-chain accounting is symmetric.

Access control uses a single `AccessControl<MERCHANT>` registry with three operational
roles:

- **`MerchantRole`** — payout address, mint config, display name
- **`CatalogManagerRole`** — listings + variants CRUD + active toggle
- **`CashierRole`** — invoice issuance + voucher redemption

The deployer is the root holder and grants operational roles separately, so
cold-storage admin keys stay out of daily POS operations.

## Repository Layout

```
contracts/
├── payments/         # The template (8 modules + 5 test files)
└── stablecoin-mock/  # Devnet-only mock PAS stablecoin (for end-to-end tests)
vendor/
└── pas/              # Vendored Permissioned Asset Standard
```
