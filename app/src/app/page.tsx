"use client";

import { useEffect } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useCurrentAccount } from "@mysten/dapp-kit";
import { Coins, Store } from "lucide-react";

import { ConnectButton } from "@/components/connect-button";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { useHasMerchantRole } from "@/hooks/use-has-merchant-role";

/**
 * Landing page. Login lives here — once the user connects a wallet we check
 * whether the address holds any staff role on the merchant's
 * `AccessControl<MERCHANT>` and route them straight to the appropriate
 * dashboard. The manual "Continue as X" cards stay as an override for users
 * exploring the app without a wallet (or wanting to preview the other role).
 */
export default function LandingPage() {
  const router = useRouter();
  const account = useCurrentAccount();
  const address = account?.address ?? null;
  const roleQuery = useHasMerchantRole(address);

  useEffect(() => {
    if (!address) return;
    if (roleQuery.isLoading || roleQuery.isError) return;
    // `router.replace` — no back-button history for the landing page.
    router.replace(roleQuery.data ? "/merchant/catalogue" : "/customer");
  }, [address, roleQuery.data, roleQuery.isLoading, roleQuery.isError, router]);

  // Show the "routing…" status box only while the role check is in-flight or
  // has succeeded (the effect above then handles the redirect). On error we
  // fall through to the manual cards so the user always has a way forward.
  const showRoutingStatus = Boolean(address) && !roleQuery.isError;

  return (
    <main className="mx-auto flex min-h-screen w-full max-w-5xl flex-col gap-12 px-6 py-12">
      <header className="flex items-start justify-between gap-4">
        <div className="flex flex-col gap-3">
          <h1 className="text-4xl font-semibold tracking-tight">
            OpenZeppelin Sui Payments
          </h1>
          <p className="max-w-xl text-sm text-[color:var(--color-muted-foreground)]">
            Closed-loop stablecoin payments and loyalty rewards on Sui. Log in
            and we&apos;ll take you to your dashboard — merchants land on
            Catalogue, everyone else lands on the customer view.
          </p>
        </div>
        <ConnectButton />
      </header>

      {showRoutingStatus ? (
        <div className="rounded-lg border border-dashed border-[color:var(--color-border)] p-12 text-center text-sm text-[color:var(--color-muted-foreground)]">
          {roleQuery.isLoading
            ? "Checking your access…"
            : `Redirecting to ${roleQuery.data ? "the merchant dashboard" : "your customer home"}…`}
        </div>
      ) : (
        <div className="grid w-full grid-cols-1 gap-6 md:grid-cols-2">
          <Card>
            <CardHeader>
              <Store className="h-8 w-8 text-[color:var(--color-primary)]" />
              <CardTitle>Merchant</CardTitle>
              <CardDescription>
                Manage your product catalogue, issue invoices, view sales, and
                redeem customer vouchers.
              </CardDescription>
            </CardHeader>
            <CardContent>
              <Button asChild size="lg" className="w-full">
                <Link href="/merchant/catalogue">Continue as merchant</Link>
              </Button>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <Coins className="h-8 w-8 text-[color:var(--color-primary)]" />
              <CardTitle>Customer</CardTitle>
              <CardDescription>
                Scan to pay, top up your balance, browse rewards, and view your
                receipt history.
              </CardDescription>
            </CardHeader>
            <CardContent>
              <Button asChild size="lg" variant="secondary" className="w-full">
                <Link href="/customer">Continue as customer</Link>
              </Button>
            </CardContent>
          </Card>
        </div>
      )}
    </main>
  );
}
