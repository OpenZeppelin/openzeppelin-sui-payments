/**
 * Switch the active network the dev server sees, without re-running bootstrap.
 *
 *   pnpm use localnet   # copies .env.localnet -> .env.local
 *   pnpm use testnet    # copies .env.testnet  -> .env.local
 *   pnpm use mainnet    # copies .env.mainnet  -> .env.local
 *
 * `.env.<network>` files are the per-network source of truth (written by
 * `pnpm bootstrap <network>`). `.env.local` is a mirror of whichever is
 * currently active — Next.js reads it on dev-server start.
 */

import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const APP_DIR = resolve(__dirname, "..");

const NETWORKS = ["localnet", "testnet", "mainnet"] as const;
type Network = (typeof NETWORKS)[number];

function main(): void {
  const arg = process.argv[2];
  if (!arg || !(NETWORKS as readonly string[]).includes(arg)) {
    console.error(
      `usage: pnpm use <${NETWORKS.join("|")}>\n\n` +
        `Copies .env.<network> to .env.local so the dev server points at that ` +
        `network's deployment. Run \`pnpm bootstrap <network>\` first to create ` +
        `the per-network file.`,
    );
    process.exit(1);
  }
  const network = arg as Network;
  const source = resolve(APP_DIR, `.env.${network}`);
  const dest = resolve(APP_DIR, ".env.local");

  if (!existsSync(source)) {
    console.error(
      `no ${source} found — run \`pnpm bootstrap ${network}\` first to create it.`,
    );
    process.exit(1);
  }

  // Temp + rename with mode 0o600. `.env.local` holds DEPLOYER_PRIVATE_KEY
  // and ENOKI_PRIVATE_API_KEY; the default `copyFileSync` inherits the
  // source's mode (typically 0644 = world-readable) and is not atomic — an
  // interrupt mid-copy would truncate the mirror.
  const tmp = `${dest}.tmp`;
  writeFileSync(tmp, readFileSync(source), { mode: 0o600 });
  renameSync(tmp, dest);
  console.log(`✓ Copied ${source}\n     to ${dest}`);
  console.log(`\nRestart the dev server (\`pnpm dev\`) so the change takes effect.`);
}

main();
