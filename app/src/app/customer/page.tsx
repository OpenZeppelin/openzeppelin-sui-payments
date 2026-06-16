import Link from "next/link";
import { Coins, History, QrCode, ShoppingBag } from "lucide-react";

import { ConnectButton } from "@/components/connect-button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";

const cards = [
  { title: "Scan to pay", icon: QrCode, description: "Scan a merchant invoice QR or paste an ID." },
  { title: "Top up", icon: Coins, description: "Fund your stablecoin balance (devnet faucet)." },
  { title: "Rewards", icon: ShoppingBag, description: "Spend loyalty points on free drinks." },
  { title: "History", icon: History, description: "Past receipts owned by your account." },
];

export default function CustomerPage() {
  return (
    <main className="mx-auto flex min-h-screen w-full max-w-4xl flex-col gap-8 px-6 py-8">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-semibold">Customer</h1>
          <p className="text-sm text-[color:var(--color-muted-foreground)]">
            Pay merchants, earn loyalty, redeem rewards — gas-free.
          </p>
        </div>
        <div className="flex items-center gap-4">
          <Link
            href="/"
            className="text-sm text-[color:var(--color-muted-foreground)] hover:underline"
          >
            Switch role
          </Link>
          <ConnectButton />
        </div>
      </header>

      <Card>
        <CardHeader>
          <CardDescription>Total balance</CardDescription>
        </CardHeader>
        <CardContent className="grid grid-cols-2 gap-6">
          <div>
            <div className="text-xs uppercase tracking-wide text-[color:var(--color-muted-foreground)]">
              Stablecoin
            </div>
            <div className="mt-1 text-2xl font-semibold">— USD</div>
          </div>
          <div>
            <div className="text-xs uppercase tracking-wide text-[color:var(--color-muted-foreground)]">
              Loyalty points
            </div>
            <div className="mt-1 text-2xl font-semibold">— LOY</div>
          </div>
        </CardContent>
      </Card>

      <div className="grid grid-cols-2 gap-4">
        {cards.map(({ title, icon: Icon, description }) => (
          <Card
            key={title}
            className="cursor-pointer transition-transform hover:-translate-y-0.5 hover:shadow-md"
          >
            <CardHeader>
              <Icon className="h-7 w-7 text-[color:var(--color-primary)]" />
              <CardTitle>{title}</CardTitle>
              <CardDescription>{description}</CardDescription>
            </CardHeader>
          </Card>
        ))}
      </div>
    </main>
  );
}
