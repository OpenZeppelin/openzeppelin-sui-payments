"use client";

import { ErrorFallback } from "@/components/shared/error-fallback";

/**
 * Root-segment error boundary. Catches uncaught throws from the landing
 * page (`app/page.tsx`) or any route that lacks its own `error.tsx` and
 * bubbles here. Sibling `merchant/error.tsx` + `customer/error.tsx` catch
 * their subtrees first, so this one really only fires on the landing page.
 */
export default function RootError(props: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  return <ErrorFallback {...props} scope="app" />;
}
