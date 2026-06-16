import Link from "next/link";
import { LayoutGrid, Receipt, Wallet, QrCode } from "lucide-react";

const nav = [
  { href: "/merchant/catalogue", label: "Catalogue", icon: LayoutGrid },
  { href: "/merchant/transactions", label: "Transactions", icon: Receipt },
  { href: "/merchant/balance", label: "Balance", icon: Wallet },
  { href: "/merchant/redeem", label: "Redeem", icon: QrCode },
];

export default function MerchantLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="grid min-h-screen grid-cols-[16rem_1fr]">
      <aside className="border-r border-[color:var(--color-border)] bg-[color:var(--color-card)] p-6">
        <Link href="/" className="text-lg font-semibold">
          Merchant
        </Link>
        <nav className="mt-8 flex flex-col gap-1">
          {nav.map(({ href, label, icon: Icon }) => (
            <Link
              key={href}
              href={href}
              className="flex items-center gap-3 rounded-md px-3 py-2 text-sm text-[color:var(--color-muted-foreground)] transition-colors hover:bg-[color:var(--color-muted)] hover:text-[color:var(--color-foreground)]"
            >
              <Icon className="h-4 w-4" />
              {label}
            </Link>
          ))}
        </nav>
      </aside>
      <main className="p-8">{children}</main>
    </div>
  );
}
