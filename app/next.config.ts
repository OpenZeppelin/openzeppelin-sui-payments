import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  // The @mysten packages ship modern ESM with workspace-style internals; let
  // Next transpile them so server-side and edge bundles resolve cleanly.
  transpilePackages: ["@mysten/sui", "@mysten/dapp-kit", "@mysten/enoki"],
};

export default nextConfig;
