"use client";

import { useSuiClient } from "@mysten/dapp-kit";
import type { SuiClient } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";
import { useQuery } from "@tanstack/react-query";

import { deployment } from "@/lib/deployment";
import {
  parseInvoice,
  parseListing,
  parseMerchant,
  parsePaymentReceipt,
  parseRedemptionReceipt,
  parseVoucher,
  type Invoice,
  type Listing,
  type Merchant,
  type PaymentReceipt,
  type RedemptionReceipt,
  type Voucher,
} from "@/lib/move/types";

// ---------------------------------------------------------------------------
// Query keys — keep stable so `useSponsoredMutation` can target invalidations.
// ---------------------------------------------------------------------------
export const qk = {
  merchant: () => ["merchant"] as const,
  listings: () => ["merchant", "listings"] as const,
  invoice: (id: string) => ["invoice", id] as const,
  voucher: (id: string) => ["voucher", id] as const,
  invoiceReceipt: (id: string) => ["invoiceReceipt", id] as const,
  voucherReceipt: (id: string) => ["voucherReceipt", id] as const,
  receipts: (address: string) => ["receipts", address] as const,
  balances: (accountId: string) => ["balances", accountId] as const,
  events: (type: string) => ["events", type] as const,
};

// ---------------------------------------------------------------------------
// Merchant + Listings
// ---------------------------------------------------------------------------

export function useMerchant() {
  const client = useSuiClient();
  return useQuery({
    queryKey: qk.merchant(),
    queryFn: async (): Promise<Merchant> => {
      const o = await client.getObject({
        id: deployment.merchantId,
        options: { showContent: true },
      });
      const content = (o.data?.content ?? null) as any;
      if (!content?.fields) throw new Error("Merchant not found");
      return parseMerchant(content);
    },
  });
}

/**
 * Enumerates every Listing under the Merchant's `listings: Table<ID, Listing>`.
 * Two-step: list dynamic field keys, then fetch each value in parallel.
 */
export function useListings() {
  const client = useSuiClient();
  const merchantQuery = useMerchant();
  const listingsTableId = merchantQuery.data?.listingsTableId;

  return useQuery({
    queryKey: qk.listings(),
    enabled: Boolean(listingsTableId),
    queryFn: async (): Promise<Listing[]> => {
      const out: Listing[] = [];
      let cursor: string | null = null;
      do {
        const page = await client.getDynamicFields({
          parentId: listingsTableId!,
          cursor: cursor ?? undefined,
        });
        const objects = await Promise.all(
          page.data.map((f) =>
            client.getDynamicFieldObject({
              parentId: listingsTableId!,
              name: f.name,
            }),
          ),
        );
        for (const o of objects) {
          const content = (o.data?.content ?? null) as any;
          if (!content?.fields?.value) continue;
          out.push(parseListing({ fields: content.fields.value.fields }));
        }
        cursor = page.hasNextPage ? page.nextCursor : null;
      } while (cursor);
      return out;
    },
  });
}

// ---------------------------------------------------------------------------
// Invoice / Voucher — looked up by table key (the QR value). Both live as
// `Table<ID, V>` entries on the merchant, so we read via getDynamicFieldObject
// instead of getObject (which would 404 because they're not standalone objects).
// ---------------------------------------------------------------------------

const ID_DF_NAME_TYPE = "0x2::object::ID";

async function readTableValueByIdKey<T>(
  client: SuiClient,
  parentTableId: string,
  key: string,
  parse: (key: string, raw: any) => T,
): Promise<T | null> {
  const o = await client.getDynamicFieldObject({
    parentId: parentTableId,
    name: { type: ID_DF_NAME_TYPE, value: key },
  });
  const content = (o.data?.content ?? null) as any;
  if (!content?.fields?.value) return null;
  return parse(key, { fields: content.fields.value.fields });
}

export function useInvoice(id: string | null | undefined) {
  const client = useSuiClient();
  const merchantQuery = useMerchant();
  const invoicesTableId = merchantQuery.data?.invoicesTableId;
  return useQuery({
    queryKey: qk.invoice(id ?? ""),
    enabled: Boolean(id) && Boolean(invoicesTableId),
    queryFn: async (): Promise<Invoice> => {
      const v = await readTableValueByIdKey(client, invoicesTableId!, id!, parseInvoice);
      if (!v) throw new Error(`Invoice ${id} not found (already settled or canceled)`);
      return v;
    },
  });
}

export function useVoucher(id: string | null | undefined) {
  const client = useSuiClient();
  const merchantQuery = useMerchant();
  const vouchersTableId = merchantQuery.data?.vouchersTableId;
  return useQuery({
    queryKey: qk.voucher(id ?? ""),
    enabled: Boolean(id) && Boolean(vouchersTableId),
    queryFn: async (): Promise<Voucher> => {
      const v = await readTableValueByIdKey(client, vouchersTableId!, id!, parseVoucher);
      if (!v) throw new Error(`Voucher ${id} not found (already redeemed or canceled)`);
      return v;
    },
  });
}

/**
 * Look up the stored payment receipt for a settled invoice. Returns null when
 * no receipt is stored (invoice was canceled, not paid; or receipt was pruned).
 */
export function useInvoiceReceipt(invoiceId: string | null | undefined) {
  const client = useSuiClient();
  const merchantQuery = useMerchant();
  const tableId = merchantQuery.data?.invoiceReceiptsTableId;
  return useQuery({
    queryKey: qk.invoiceReceipt(invoiceId ?? ""),
    enabled: Boolean(invoiceId) && Boolean(tableId),
    queryFn: async (): Promise<PaymentReceipt | null> =>
      readTableValueByIdKey(client, tableId!, invoiceId!, parsePaymentReceipt),
  });
}

export function useVoucherReceipt(voucherId: string | null | undefined) {
  const client = useSuiClient();
  const merchantQuery = useMerchant();
  const tableId = merchantQuery.data?.voucherReceiptsTableId;
  return useQuery({
    queryKey: qk.voucherReceipt(voucherId ?? ""),
    enabled: Boolean(voucherId) && Boolean(tableId),
    queryFn: async (): Promise<RedemptionReceipt | null> =>
      readTableValueByIdKey(client, tableId!, voucherId!, parseRedemptionReceipt),
  });
}

// ---------------------------------------------------------------------------
// Receipts for a given customer — events-based, since receipts are no longer
// owned objects (they live in tables on the Merchant). We rebuild the customer
// history from the canonical `InvoicePaid` / `VoucherRedeemed` event stream
// and resolve each into a full receipt via the merchant tables.
// ---------------------------------------------------------------------------

export function useReceipts(address: string | null | undefined) {
  const client = useSuiClient();
  const merchantQuery = useMerchant();
  return useQuery({
    queryKey: qk.receipts(address ?? ""),
    enabled: Boolean(address) && Boolean(merchantQuery.data),
    queryFn: async () => {
      const merchant = merchantQuery.data!;
      const [paid, redeemed] = await Promise.all([
        client.queryEvents({
          query: { MoveEventType: `${deployment.packageId}::events::InvoicePaid` },
          limit: 200,
          order: "descending",
        }),
        client.queryEvents({
          query: { MoveEventType: `${deployment.packageId}::events::VoucherRedeemed` },
          limit: 200,
          order: "descending",
        }),
      ]);

      const mine = (e: any) =>
        ((e.parsedJson as Record<string, unknown> | undefined)?.customer as string | undefined) ===
        address;

      const paymentReceipts = await Promise.all(
        paid.data
          .filter(mine)
          .map((e) =>
            readTableValueByIdKey(
              client,
              merchant.invoiceReceiptsTableId,
              (e.parsedJson as { invoice_id: string }).invoice_id,
              parsePaymentReceipt,
            ),
          ),
      );
      const redemptionReceipts = await Promise.all(
        redeemed.data
          .filter(mine)
          .map((e) =>
            readTableValueByIdKey(
              client,
              merchant.voucherReceiptsTableId,
              (e.parsedJson as { voucher_id: string }).voucher_id,
              parseRedemptionReceipt,
            ),
          ),
      );

      const payment = paymentReceipts.filter((r): r is PaymentReceipt => r !== null);
      const redemption = redemptionReceipts.filter(
        (r): r is RedemptionReceipt => r !== null,
      );
      payment.sort((a, b) => Number(b.timestampMs - a.timestampMs));
      redemption.sort((a, b) => Number(b.timestampMs - a.timestampMs));
      return { payment, redemption };
    },
  });
}

// ---------------------------------------------------------------------------
// Balances on a PAS Account
// ---------------------------------------------------------------------------

/**
 * Reads `Balance<T>` totals for a PAS Account. PAS deposits go through
 * `sui::balance::send_funds`, which routes into `sui::funds_accumulator` keyed
 * by the recipient's address (NOT as a dynamic field on the account UID).
 * Sui's RPC exposes that via `client.getBalance({owner, coinType})`, where
 * `owner` is the account object's address — its `totalBalance` includes both
 * accumulated balance and any owned Coin<T>s.
 */
export function useBalances(accountId: string | null | undefined, coinTypes: string[]) {
  const client = useSuiClient();
  return useQuery({
    queryKey: [...qk.balances(accountId ?? ""), coinTypes],
    enabled: Boolean(accountId),
    queryFn: async (): Promise<Record<string, bigint>> => {
      const entries = await Promise.all(
        coinTypes.map(async (coinType) => {
          const b = await client.getBalance({ owner: accountId!, coinType });
          return [coinType, BigInt(b.totalBalance ?? "0")] as const;
        }),
      );
      return Object.fromEntries(entries);
    },
  });
}

// ---------------------------------------------------------------------------
// Events (for the merchant Transactions page)
// ---------------------------------------------------------------------------

const EVENT_TYPES = {
  InvoicePaid: `${deployment.packageId}::events::InvoicePaid`,
  InvoiceCanceled: `${deployment.packageId}::events::InvoiceCanceled`,
  VoucherRedeemed: `${deployment.packageId}::events::VoucherRedeemed`,
  VoucherCanceled: `${deployment.packageId}::events::VoucherCanceled`,
  InvoiceCreated: `${deployment.packageId}::events::InvoiceCreated`,
  VoucherCreated: `${deployment.packageId}::events::VoucherCreated`,
} as const;

export function useEvents<T extends keyof typeof EVENT_TYPES>(
  name: T,
  options: { limit?: number } = {},
) {
  const client = useSuiClient();
  return useQuery({
    queryKey: qk.events(EVENT_TYPES[name]),
    queryFn: async () => {
      const r = await client.queryEvents({
        query: { MoveEventType: EVENT_TYPES[name] },
        limit: options.limit ?? 50,
        order: "descending",
      });
      return r.data.map((e) => ({
        digest: e.id.txDigest,
        timestampMs: e.timestampMs ? BigInt(e.timestampMs) : null,
        parsed: e.parsedJson as Record<string, unknown>,
      }));
    },
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Pre-computes a customer's deterministic PAS account address via devInspect. */
export async function fetchAccountAddress(
  client: SuiClient,
  ownerAddress: string,
): Promise<string | null> {
  const tx = new Transaction();
  tx.moveCall({
    target: `${deployment.pasPackageId}::namespace::account_address`,
    arguments: [tx.object(deployment.namespaceId), tx.pure.address(ownerAddress)],
  });
  const result = await client.devInspectTransactionBlock({
    sender: ownerAddress,
    transactionBlock: tx,
  });
  const rv = result.results?.[0]?.returnValues?.[0];
  if (!rv) return null;
  const [bytes] = rv;
  return "0x" + Array.from(bytes as number[])
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}
