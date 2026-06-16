import Link from "next/link";
import { Coins, Store } from "lucide-react";

import { ConnectButton } from "@/components/connect-button";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";

export default function LandingPage() {
  return (
    <main className="mx-auto flex min-h-screen w-full max-w-5xl flex-col gap-12 px-6 py-12">
      <div className="flex items-center justify-end">
        <ConnectButton />
      </div>
      <header className="flex flex-col items-center gap-3 text-center">
        <h1 className="text-4xl font-semibold tracking-tight">
          OpenZeppelin Sui Payments
        </h1>
        <p className="max-w-xl text-sm text-[color:var(--color-muted-foreground)]">
          Closed-loop stablecoin payments and loyalty rewards on Sui. Pick a
          role to continue — you can switch at any time.
        </p>
      </header>

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
    </main>
  );
}
