"use client";

import { useSuiClient } from "@mysten/dapp-kit";
import type { SuiClient, SuiEvent } from "@mysten/sui/client";
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

/**
 * Fetch up to `maxPages` pages of a single `MoveEventType`, descending. We
 * scope the walk because customer-history callers filter client-side and a
 * runaway walk would blow the tab budget. For real deployments an indexer
 * replaces this call entirely.
 */
async function queryEvents(
  client: SuiClient,
  moveEventType: string,
  maxPages: number,
): Promise<SuiEvent[]> {
  const out: SuiEvent[] = [];
  let cursor: Parameters<SuiClient["queryEvents"]>[0]["cursor"] = null;
  for (let i = 0; i < maxPages; i++) {
    const page = await client.queryEvents({
      query: { MoveEventType: moveEventType },
      cursor,
      limit: 200,
      order: "descending",
    });
    out.push(...page.data);
    if (!page.hasNextPage || !page.nextCursor) break;
    cursor = page.nextCursor;
  }
  return out;
}

/**
 * Reads an invoice from `merchant.invoices` by id. Returns `null` if the
 * invoice isn't in the table — settled (paid), canceled, or never existed.
 * Callers distinguish via `data === undefined` (still loading) vs
 * `data === null` (confirmed missing). `pollMs` enables live-watching for
 * "is it still open?" UIs.
 */
export function useInvoice(
  id: string | null | undefined,
  options: { pollMs?: number } = {},
) {
  const client = useSuiClient();
  const merchantQuery = useMerchant();
  const invoicesTableId = merchantQuery.data?.invoicesTableId;
  return useQuery({
    queryKey: qk.invoice(id ?? ""),
    enabled: Boolean(id) && Boolean(invoicesTableId),
    refetchInterval: options.pollMs && options.pollMs > 0 ? options.pollMs : false,
    queryFn: async (): Promise<Invoice | null> =>
      readTableValueByIdKey(client, invoicesTableId!, id!, parseInvoice),
  });
}

export function useVoucher(
  id: string | null | undefined,
  options: { pollMs?: number } = {},
) {
  const client = useSuiClient();
  const merchantQuery = useMerchant();
  const vouchersTableId = merchantQuery.data?.vouchersTableId;
  return useQuery({
    queryKey: qk.voucher(id ?? ""),
    enabled: Boolean(id) && Boolean(vouchersTableId),
    refetchInterval: options.pollMs && options.pollMs > 0 ? options.pollMs : false,
    queryFn: async (): Promise<Voucher | null> =>
      readTableValueByIdKey(client, vouchersTableId!, id!, parseVoucher),
  });
}

/**
 * Enumerates *open* vouchers (still in `merchant.vouchers`) belonging to a
 * specific customer address. `VoucherCreated` events only carry `voucher_id`
 * — they don't index by customer — so we read the table and filter client-side.
 * Cheap for demo volumes, would need indexing service at scale.
 */
export function useMyOpenVouchers(customerAddress: string | null | undefined) {
  const client = useSuiClient();
  const merchantQuery = useMerchant();
  const vouchersTableId = merchantQuery.data?.vouchersTableId;
  return useQuery({
    queryKey: ["my-open-vouchers", customerAddress ?? ""],
    enabled: Boolean(customerAddress) && Boolean(vouchersTableId),
    queryFn: async (): Promise<Voucher[]> => {
      const out: Voucher[] = [];
      let cursor: string | null = null;
      do {
        const page = await client.getDynamicFields({
          parentId: vouchersTableId!,
          cursor: cursor ?? undefined,
        });
        const objects = await Promise.all(
          page.data.map((f) =>
            client.getDynamicFieldObject({
              parentId: vouchersTableId!,
              name: f.name,
            }),
          ),
        );
        for (const o of objects) {
          const content = (o.data?.content ?? null) as any;
          if (!content?.fields?.value) continue;
          const key = content.fields.name as string;
          const v = parseVoucher(key, { fields: content.fields.value.fields });
          if (v.customer === customerAddress) out.push(v);
        }
        cursor = page.hasNextPage ? page.nextCursor : null;
      } while (cursor);
      out.sort((a, b) => Number(b.expiresAtMs - a.expiresAtMs));
      return out;
    },
  });
}

/**
 * Enumerates the keys (= settled invoice/voucher ids) of all receipts currently
 * stored on the merchant. Used by the "Prune receipts" button to know how many
 * there are and which ids to pass into `prune_*_receipts`.
 */
export function useStoredReceipts(options: { pollMs?: number } = {}) {
  const client = useSuiClient();
  const merchantQuery = useMerchant();
  const inv = merchantQuery.data?.invoiceReceiptsTableId;
  const vou = merchantQuery.data?.voucherReceiptsTableId;
  return useQuery({
    queryKey: ["stored-receipts", inv ?? "", vou ?? ""],
    enabled: Boolean(inv) && Boolean(vou),
    refetchInterval: options.pollMs && options.pollMs > 0 ? options.pollMs : false,
    queryFn: async (): Promise<{ invoice: string[]; voucher: string[] }> => {
      const enumerate = async (parentId: string): Promise<string[]> => {
        const keys: string[] = [];
        let cursor: string | null = null;
        do {
          const page = await client.getDynamicFields({
            parentId,
            cursor: cursor ?? undefined,
          });
          for (const f of page.data) {
            // For a `Table<ID, V>` the dynamic field name carries the key
            // as `{ type: "0x2::object::ID", value: "0x.." }`.
            const name = f.name as { value?: string } | undefined;
            if (name?.value) keys.push(name.value);
          }
          cursor = page.hasNextPage ? (page.nextCursor ?? null) : null;
        } while (cursor);
        return keys;
      };
      const [invoice, voucher] = await Promise.all([enumerate(inv!), enumerate(vou!)]);
      return { invoice, voucher };
    },
  });
}

/**
 * Look up the stored payment receipt for a settled invoice. Returns null when
 * no receipt is stored (invoice was canceled, not paid; or receipt was pruned).
 * `pollMs` enables periodic refetch — useful for "watch for payment while QR
 * is on screen" UI; pass undefined / 0 to disable polling.
 */
export function useInvoiceReceipt(
  invoiceId: string | null | undefined,
  options: { pollMs?: number } = {},
) {
  const client = useSuiClient();
  const merchantQuery = useMerchant();
  const tableId = merchantQuery.data?.invoiceReceiptsTableId;
  return useQuery({
    queryKey: qk.invoiceReceipt(invoiceId ?? ""),
    enabled: Boolean(invoiceId) && Boolean(tableId),
    refetchInterval: options.pollMs && options.pollMs > 0 ? options.pollMs : false,
    queryFn: async (): Promise<PaymentReceipt | null> =>
      readTableValueByIdKey(client, tableId!, invoiceId!, parsePaymentReceipt),
  });
}

export function useVoucherReceipt(
  voucherId: string | null | undefined,
  options: { pollMs?: number } = {},
) {
  const client = useSuiClient();
  const merchantQuery = useMerchant();
  const tableId = merchantQuery.data?.voucherReceiptsTableId;
  return useQuery({
    queryKey: qk.voucherReceipt(voucherId ?? ""),
    enabled: Boolean(voucherId) && Boolean(tableId),
    refetchInterval: options.pollMs && options.pollMs > 0 ? options.pollMs : false,
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

export function useReceipts(
  address: string | null | undefined,
  options: { pollMs?: number } = {},
) {
  const client = useSuiClient();
  const merchantQuery = useMerchant();
  return useQuery({
    queryKey: qk.receipts(address ?? ""),
    enabled: Boolean(address) && Boolean(merchantQuery.data),
    // Redemptions happen on the cashier side (a different tab / device from
    // the customer), so the customer's history has no cross-client
    // invalidation path. Poll while the page is open to pick them up.
    refetchInterval: options.pollMs && options.pollMs > 0 ? options.pollMs : false,
    queryFn: async () => {
      const merchant = merchantQuery.data!;
      // Filter by customer client-side. The compound `{ All: [MoveEventType,
      // MoveEventField] }` filter returns "Invalid params" on public testnet
      // fullnodes (the RPC parser rejects the compound form entirely), so
      // server-side filtering by `/customer` is not viable. Fetch by event
      // type, then filter the parsedJson. Page walk is capped at MAX_PAGES —
      // at scale a template deployment should be paired with a real indexer.
      const MAX_PAGES = 5;
      const [paid, redeemed] = await Promise.all([
        queryEvents(client, `${deployment.packageId}::events::InvoicePaid`, MAX_PAGES),
        queryEvents(client, `${deployment.packageId}::events::VoucherRedeemed`, MAX_PAGES),
      ]);

      const mine = (e: SuiEvent) =>
        (e.parsedJson as { customer?: string } | undefined)?.customer === address;

      const paymentReceipts = await Promise.all(
        paid.filter(mine).map((e) =>
          readTableValueByIdKey(
            client,
            merchant.invoiceReceiptsTableId,
            (e.parsedJson as { invoice_id: string }).invoice_id,
            parsePaymentReceipt,
          ),
        ),
      );
      const redemptionReceipts = await Promise.all(
        redeemed.filter(mine).map((e) =>
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
  options: { limit?: number; pollMs?: number } = {},
) {
  const client = useSuiClient();
  return useQuery({
    queryKey: qk.events(EVENT_TYPES[name]),
    refetchInterval: options.pollMs && options.pollMs > 0 ? options.pollMs : false,
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
