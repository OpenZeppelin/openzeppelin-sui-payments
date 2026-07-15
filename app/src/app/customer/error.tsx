"use client";

import { ErrorFallback } from "@/components/shared/error-fallback";

/**
 * Customer-segment error boundary. Wraps every customer page beneath the
 * `customer/layout.tsx` header shell - an uncaught throw in `pay`,
 * `rewards`, `topup`, `history`, or the dashboard renders here instead of
 * blank-white-screening the whole app. The header layout itself stays
 * intact because it lives above this boundary.
 */
export default function CustomerError(props: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  return <ErrorFallback {...props} scope="customer flow" />;
}
