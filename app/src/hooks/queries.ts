"use client";

import { useSuiClient } from "@mysten/dapp-kit";
import type { SuiClient } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";
import { useQuery, useQueries } from "@tanstack/react-query";

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
          // Dynamic field wraps the value: { value: { fields: <Listing fields> } }
          out.push(parseListing({ fields: content.fields.value.fields }));
        }
        cursor = page.hasNextPage ? page.nextCursor : null;
      } while (cursor);
      return out;
    },
  });
}

// ---------------------------------------------------------------------------
// Invoice / Voucher (looked up by id, e.g. from a scanned QR)
// ---------------------------------------------------------------------------

export function useInvoice(id: string | null | undefined) {
  const client = useSuiClient();
  return useQuery({
    queryKey: qk.invoice(id ?? ""),
    enabled: Boolean(id),
    queryFn: async (): Promise<Invoice> => {
      const o = await client.getObject({ id: id!, options: { showContent: true } });
      const content = (o.data?.content ?? null) as any;
      if (!content?.fields) throw new Error(`Invoice ${id} not found`);
      return parseInvoice(content);
    },
  });
}

export function useVoucher(id: string | null | undefined) {
  const client = useSuiClient();
  return useQuery({
    queryKey: qk.voucher(id ?? ""),
    enabled: Boolean(id),
    queryFn: async (): Promise<Voucher> => {
      const o = await client.getObject({ id: id!, options: { showContent: true } });
      const content = (o.data?.content ?? null) as any;
      if (!content?.fields) throw new Error(`Voucher ${id} not found`);
      return parseVoucher(content);
    },
  });
}

// ---------------------------------------------------------------------------
// Receipts owned by an address (filtered + split by payload variant)
// ---------------------------------------------------------------------------

export function useReceipts(address: string | null | undefined) {
  const client = useSuiClient();
  return useQuery({
    queryKey: qk.receipts(address ?? ""),
    enabled: Boolean(address),
    queryFn: async () => {
      const payment: PaymentReceipt[] = [];
      const redemption: RedemptionReceipt[] = [];
      let cursor: string | null = null;
      const paymentType = `${deployment.packageId}::receipt::Receipt<${deployment.packageId}::receipt::Payment>`;
      const redemptionType = `${deployment.packageId}::receipt::Receipt<${deployment.packageId}::receipt::Redemption>`;
      do {
        const page = await client.getOwnedObjects({
          owner: address!,
          options: { showContent: true, showType: true },
          cursor: cursor ?? undefined,
        });
        for (const e of page.data) {
          const type = e.data?.type ?? "";
          const content = (e.data?.content ?? null) as any;
          if (!content?.fields) continue;
          if (type === paymentType) payment.push(parsePaymentReceipt(content));
          else if (type === redemptionType) redemption.push(parseRedemptionReceipt(content));
        }
        cursor = page.hasNextPage ? page.nextCursor : null;
      } while (cursor);

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
 * Reads `Balance<T>` values stored as dynamic fields under a PAS Account.
 * `coinTypes` filters which types to return (e.g. `[stablecoinType, loyaltyType]`).
 */
export function useBalances(accountId: string | null | undefined, coinTypes: string[]) {
  const client = useSuiClient();
  return useQuery({
    queryKey: [...qk.balances(accountId ?? ""), coinTypes],
    enabled: Boolean(accountId),
    queryFn: async (): Promise<Record<string, bigint>> => {
      const result: Record<string, bigint> = Object.fromEntries(coinTypes.map((t) => [t, 0n]));
      let cursor: string | null = null;
      do {
        const page = await client.getDynamicFields({
          parentId: accountId!,
          cursor: cursor ?? undefined,
        });
        for (const f of page.data) {
          // Dynamic field name on PAS accounts is the coin type tag; the value
          // is the `Balance<T>`. We don't unpack here — just read its `.value`.
          const obj = await client.getDynamicFieldObject({
            parentId: accountId!,
            name: f.name,
          });
          const content = (obj.data?.content ?? null) as any;
          if (!content?.fields) continue;
          // Detect which coin this is and accumulate.
          const innerType: string = f.objectType ?? "";
          for (const target of coinTypes) {
            if (innerType.includes(target)) {
              const value = BigInt(
                content.fields.value?.fields?.value ??
                  content.fields.value?.value ??
                  0,
              );
              result[target] = (result[target] ?? 0n) + value;
            }
          }
        }
        cursor = page.hasNextPage ? page.nextCursor : null;
      } while (cursor);
      return result;
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

/**
 * Convenience: parallel queries across all the indexer-read events so a
 * Transactions page can render one merged feed.
 */
export function useAllEvents() {
  return useQueries({
    queries: Object.keys(EVENT_TYPES).map((name) => ({
      queryKey: qk.events(EVENT_TYPES[name as keyof typeof EVENT_TYPES]),
      queryFn: async () => name, // placeholder, useEvents above carries the impl
    })),
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
  try {
    const tx = new Transaction();
    tx.moveCall({
      target: `${deployment.pasPackageId}::account::account_address`,
      arguments: [tx.object(deployment.namespaceId), tx.pure.address(ownerAddress)],
    });
    const result = await client.devInspectTransactionBlock({
      sender: ownerAddress,
      transactionBlock: tx,
    });
    const rv = result.results?.[0]?.returnValues?.[0];
    if (!rv) return null;
    // returnValues is [bytes, type]; bytes is a BCS-encoded address (32 bytes).
    const [bytes] = rv;
    return "0x" + Array.from(bytes as number[])
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");
  } catch {
    return null;
  }
}
