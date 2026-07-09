"use client";

import { useSuiClient } from "@mysten/dapp-kit";
import { useQuery } from "@tanstack/react-query";

/**
 * Current on-chain time in ms, read from the shared `Clock` object at `0x6`.
 * The chain's clock is what invoice/voucher `expires_at_ms` is set against
 * (`expires_at_ms = clock.timestamp_ms() + ttl_ms`), so comparing wallclock
 * against it is wrong when the two drift — most visibly on localnet, where
 * the on-chain clock only advances on checkpoints and can lag wallclock by
 * many minutes if the node was paused. Uses `undefined` while loading so
 * callers can fall back to `Date.now()` for the very first render.
 *
 * Polls (default 5s) so expired badges flip on time without a page reload.
 */
export function useSuiClockMs(pollMs = 5_000) {
  const client = useSuiClient();
  return useQuery({
    queryKey: ["sui-clock"],
    queryFn: async (): Promise<bigint> => {
      const obj = await client.getObject({ id: "0x6", options: { showContent: true } });
      const ts = (
        obj.data?.content as { fields?: { timestamp_ms?: string } } | null | undefined
      )?.fields?.timestamp_ms;
      if (!ts) throw new Error("Could not read Clock object at 0x6");
      return BigInt(ts);
    },
    refetchInterval: pollMs && pollMs > 0 ? pollMs : false,
  });
}
