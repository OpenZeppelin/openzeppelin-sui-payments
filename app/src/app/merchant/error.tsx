"use client";

import { ErrorFallback } from "@/components/shared/error-fallback";

/**
 * Merchant-segment error boundary. Wraps every merchant page beneath the
 * `merchant/layout.tsx` sidebar shell - an uncaught throw in `catalogue`,
 * `redeem`, `transactions`, `balance`, or `settings` renders here instead
 * of blank-white-screening the whole dashboard. The sidebar layout itself
 * stays intact because it lives above this boundary.
 */
export default function MerchantError(props: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  return <ErrorFallback {...props} scope="merchant dashboard" />;
}
