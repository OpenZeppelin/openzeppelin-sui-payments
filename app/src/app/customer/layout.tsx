"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { ArrowLeft } from "lucide-react";

import { ConnectButton } from "@/components/connect-button";

export default function CustomerLayout({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  const onSubpage = pathname !== "/customer";

  return (
    <div className="min-h-screen bg-[color:var(--color-background)]">
      <header className="border-b border-[color:var(--color-border)] bg-[color:var(--color-card)]">
        <div className="mx-auto flex h-14 max-w-4xl items-center justify-between px-6">
          {onSubpage ? (
            <Link
              href="/customer"
              className="flex items-center gap-2 text-sm text-[color:var(--color-muted-foreground)] hover:text-[color:var(--color-foreground)]"
            >
              <ArrowLeft className="h-4 w-4" />
              Back
            </Link>
          ) : (
            <Link href="/customer" className="text-lg font-semibold">
              Customer
            </Link>
          )}
          <div className="flex items-center gap-4">
            <Link
              href="/"
              className="text-sm text-[color:var(--color-muted-foreground)] hover:underline"
            >
              Switch role
            </Link>
            <ConnectButton />
          </div>
        </div>
      </header>
      <main className="mx-auto w-full max-w-4xl px-6 py-8">{children}</main>
    </div>
  );
}
