import type { Metadata } from "next";
import { Toaster } from "sonner";

import { Providers } from "@/components/providers";

import "./globals.css";

export const metadata: Metadata = {
  title: "OpenZeppelin Sui Payments",
  description:
    "Closed-loop stablecoin payments + loyalty + voucher redemption template (Sui).",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body className="min-h-screen antialiased">
        <Providers>
          {children}
          <Toaster richColors position="top-right" />
        </Providers>
      </body>
    </html>
  );
}
