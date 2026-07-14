"use client";

import { useEffect } from "react";
import Link from "next/link";
import { AlertTriangle } from "lucide-react";

import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";

/**
 * Shared fallback UI for Next.js App Router error boundaries. Rendered by
 * the per-segment `error.tsx` files: an uncaught throw below a segment is
 * caught here rather than white-screening the whole dashboard.
 *
 * `reset()` clears the boundary and re-renders the same subtree; useful for
 * transient failures (RPC hiccups, wallet reconnects). The "Back to home"
 * fallback is a hard escape when the segment itself is broken.
 */
export function ErrorFallback({
  error,
  reset,
  scope,
}: {
  error: Error & { digest?: string };
  reset: () => void;
  /** Human label describing what the boundary wraps (e.g. "merchant dashboard"). */
  scope: string;
}) {
  // Log the caught error to the console so we don't lose the stack when the
  // dev overlay is closed. Next.js also reports these via its own overlay
  // during development.
  useEffect(() => {
    console.error(`[error boundary: ${scope}]`, error);
  }, [error, scope]);

  return (
    <div className="mx-auto flex min-h-[50vh] w-full max-w-lg items-center justify-center p-6">
      <Card className="w-full">
        <CardHeader>
          <div className="flex items-center gap-2 text-[color:var(--color-destructive)]">
            <AlertTriangle className="h-5 w-5" />
            <CardTitle>Something went wrong</CardTitle>
          </div>
          <CardDescription>
            An error was thrown inside the {scope}. The rest of the app is
            still running - try again, or head back to the landing page.
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-4">
          <pre className="max-h-40 overflow-auto rounded-md border border-[color:var(--color-border)] bg-[color:var(--color-muted)] p-3 text-xs">
            {error.message || String(error)}
            {error.digest ? `\n\n[digest: ${error.digest}]` : ""}
          </pre>
          <div className="flex items-center justify-end gap-2">
            <Button asChild variant="ghost">
              <Link href="/">Back to home</Link>
            </Button>
            <Button onClick={reset}>Try again</Button>
          </div>
        </CardContent>
      </Card>
    </div>
  );
}
