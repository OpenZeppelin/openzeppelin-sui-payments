"use client";

import { useEffect, useState } from "react";
import { SuiClientProvider, WalletProvider, useSuiClient } from "@mysten/dapp-kit";
import { registerEnokiWallets } from "@mysten/enoki";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";

import { NETWORK, networkConfig } from "@/lib/sui-client";
import { enokiPublicKey } from "@/lib/deployment";

// Side-effect CSS import: pulls in dapp-kit's modal styles. Has to live here
// (in a JS module) rather than in globals.css because dapp-kit's exports map
// only declares `import`/`require` conditions, not `style`. TS can't type
// the side-effect import — see `src/types/css.d.ts` for the ambient module.
import "@mysten/dapp-kit/dist/index.css";

/**
 * Registers Enoki zkLogin wallets into the wallet-standard registry so they
 * appear in dapp-kit's ConnectButton modal as a normal "Log in with Google"
 * option. Lives in a child component so it can pull the canonical SuiClient
 * out of `useSuiClient()` (which has the right type for Enoki's API).
 */
function EnokiWalletRegistration() {
  const suiClient = useSuiClient();

  useEffect(() => {
    if (!enokiPublicKey) return;
    if (NETWORK !== "testnet" && NETWORK !== "mainnet" && NETWORK !== "devnet") return;

    const { unregister } = registerEnokiWallets({
      // pnpm has hoisted two @mysten/sui versions (dapp-kit + enoki resolved
      // to different ranges); the SuiClient nominal types diverge across them
      // even though the runtime objects are interchangeable. Cast through
      // `unknown` so TS accepts the assignment until the dual-version issue
      // is resolved at the pnpm override layer.
      client: suiClient as unknown as Parameters<typeof registerEnokiWallets>[0]["client"],
      apiKey: enokiPublicKey,
      network: NETWORK,
      providers: {
        google: {
          clientId:
            process.env.NEXT_PUBLIC_GOOGLE_CLIENT_ID ??
            "PLACEHOLDER_GOOGLE_CLIENT_ID",
          // Pin the OAuth redirect to a single stable URL so Google's OAuth
          // client only needs one entry in Authorized redirect URIs. Without
          // this, Enoki defaults to the current page URL — meaning every
          // page a user might click Login from would need its own URI in
          // Google Cloud Console.
          redirectUrl: `${window.location.origin}/auth/callback`,
        },
      },
    });

    return () => unregister();
  }, [suiClient]);

  return null;
}

/**
 * Top-level client provider stack. Order matters:
 *   QueryClientProvider → SuiClientProvider → WalletProvider
 */
export function Providers({ children }: { children: React.ReactNode }) {
  const [queryClient] = useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: { staleTime: 30_000, refetchOnWindowFocus: false },
        },
      }),
  );

  return (
    <QueryClientProvider client={queryClient}>
      <SuiClientProvider networks={networkConfig} defaultNetwork={NETWORK}>
        <EnokiWalletRegistration />
        {/* Per-tab wallet state: default `storage` is `localStorage`, which
            leaks across tabs/windows of the same origin (auto-connect fires
            everywhere the moment one tab connects). Using `sessionStorage`
            isolates that state per browsing context — you can run two
            windows side-by-side (e.g. one merchant, one customer) without
            one flipping the other's connection.
            No walletFilter — any wallet-standard wallet (browser extension,
            Enoki zkLogin, etc.) shows up in the connect modal. */}
        <WalletProvider
          autoConnect
          storage={typeof window !== "undefined" ? window.sessionStorage : undefined}
        >
          {children}
        </WalletProvider>
      </SuiClientProvider>
    </QueryClientProvider>
  );
}

