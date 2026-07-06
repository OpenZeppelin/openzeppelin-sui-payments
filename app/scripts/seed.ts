/**
 * Seed the catalog with a small menu using the deployer's `CatalogManagerRole`.
 *
 * Idempotent by refusal: bootstrap grants the deployer every operational role,
 * so a seed is a one-shot; if `merchant.listings` already has any entries we
 * abort rather than duplicate. Delete the listings via the catalogue UI (or
 * run against a fresh chain) before re-seeding.
 *
 * Prices:
 *   - `price` is in stablecoin base units. Mock USD uses 6 decimals, so $1 = 1e6.
 *   - `loyalty_price` is in LOYALTY base units (0 decimals). `null` = not
 *     redeemable for LOY.
 */

import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { SuiClient } from "@mysten/sui/client";
import { Transaction, type TransactionArgument } from "@mysten/sui/transactions";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const APP_DIR = resolve(__dirname, "..");
const ENV_PATH = resolve(APP_DIR, ".env.local");

const STABLECOIN_UNIT = 1_000_000n; // 6 decimals

interface VariantSpec {
  name: string;
  /** Price in USD (whole dollars). */
  usd: bigint;
  /** Optional loyalty price in LOY units (0 decimals). */
  loy: bigint | null;
}

interface ListingSpec {
  name: string;
  variants: VariantSpec[];
}

const CATALOG: ListingSpec[] = [
  {
    name: "Espresso",
    variants: [
      { name: "S", usd: 1n, loy: 1n },
      { name: "M", usd: 2n, loy: 2n },
      { name: "L", usd: 3n, loy: 3n },
    ],
  },
  {
    name: "Black coffee",
    variants: [
      { name: "S", usd: 3n, loy: 3n },
      { name: "M", usd: 5n, loy: 5n },
      { name: "L", usd: 7n, loy: 7n },
    ],
  },
  {
    name: "Matcha",
    variants: [
      { name: "S", usd: 2n, loy: null },
      { name: "M", usd: 4n, loy: null },
      { name: "L", usd: 6n, loy: null },
    ],
  },
  {
    name: "Chai latte",
    variants: [
      { name: "S", usd: 3n, loy: null },
      { name: "M", usd: 5n, loy: null },
      { name: "L", usd: 7n, loy: null },
    ],
  },
];

/** Read a `KEY=value` line from `.env.local`. tsx doesn't auto-load it. */
function readEnv(key: string): string {
  let raw = "";
  try {
    raw = readFileSync(ENV_PATH, "utf8");
  } catch {
    throw new Error(`could not read ${ENV_PATH} — run \`pnpm bootstrap\` first`);
  }
  const line = raw.split("\n").find((l) => l.startsWith(`${key}=`));
  if (!line) throw new Error(`missing ${key} in ${ENV_PATH} — run \`pnpm bootstrap\` first`);
  return line.slice(key.length + 1).trim();
}

function networkUrl(network: string): string {
  if (network === "localnet") return "http://127.0.0.1:9000";
  if (network === "testnet") return "https://fullnode.testnet.sui.io:443";
  if (network === "mainnet") return "https://fullnode.mainnet.sui.io:443";
  if (network === "devnet") return "https://fullnode.devnet.sui.io:443";
  throw new Error(`unknown NEXT_PUBLIC_SUI_NETWORK: ${network}`);
}

async function main(): Promise<void> {
  const network = readEnv("NEXT_PUBLIC_SUI_NETWORK");
  const packageId = readEnv("NEXT_PUBLIC_PACKAGE_ID");
  const merchantId = readEnv("NEXT_PUBLIC_MERCHANT_ID");
  const accessControlId = readEnv("NEXT_PUBLIC_ACCESS_CONTROL_ID");
  const ozAccessPkg = readEnv("NEXT_PUBLIC_OZ_ACCESS_PACKAGE_ID");
  const deployerKey = readEnv("DEPLOYER_PRIVATE_KEY");

  const client = new SuiClient({ url: networkUrl(network) });
  const keypair = Ed25519Keypair.fromSecretKey(decodeSuiPrivateKey(deployerKey).secretKey);
  const deployer = keypair.toSuiAddress();
  console.log(`network: ${network}`);
  console.log(`deployer: ${deployer}`);
  console.log(`merchant: ${merchantId}`);

  // Fail fast if the catalog already has anything. Read the listings table id
  // via the merchant object, then check for any dynamic field.
  const merchantObj = await client.getObject({ id: merchantId, options: { showContent: true } });
  const fields = (merchantObj.data?.content as { fields?: { listings?: { fields?: { id?: { id?: string } } } } } | null | undefined)?.fields;
  const listingsTableId = fields?.listings?.fields?.id?.id;
  if (!listingsTableId) throw new Error("could not locate merchant.listings table");
  const existing = await client.getDynamicFields({ parentId: listingsTableId, limit: 1 });
  if (existing.data.length > 0) {
    throw new Error(
      `refusing to seed — merchant.listings already has ${existing.data.length}+ entries. ` +
        `Delete them from the Catalogue UI (or run against a fresh chain) before re-seeding.`,
    );
  }

  // Single PTB: for each listing, create + add + attach each variant. Chain the
  // returned listing id straight into `add_listing_variant` so we don't need
  // to know the ids up front.
  const tx = new Transaction();
  const acAuth = (): TransactionArgument =>
    tx.moveCall({
      target: `${ozAccessPkg}::access_control::new_auth`,
      typeArguments: [
        `${packageId}::merchant::MERCHANT`,
        `${packageId}::merchant::CatalogManagerRole`,
      ],
      arguments: [tx.object(accessControlId)],
    });
  for (const spec of CATALOG) {
    const listing = tx.moveCall({
      target: `${packageId}::listing::new`,
      arguments: [tx.pure.string(spec.name)],
    });
    const listingId = tx.moveCall({
      target: `${packageId}::merchant::add_listing`,
      arguments: [tx.object(merchantId), acAuth(), listing],
    });
    for (const v of spec.variants) {
      const variant = tx.moveCall({
        target: `${packageId}::listing::new_variant`,
        arguments: [
          tx.pure.string(v.name),
          tx.pure.u64(v.usd * STABLECOIN_UNIT),
          tx.pure.option("u64", v.loy),
        ],
      });
      tx.moveCall({
        target: `${packageId}::merchant::add_listing_variant`,
        arguments: [tx.object(merchantId), acAuth(), listingId, variant],
      });
    }
  }
  tx.setGasBudget(500_000_000n);

  console.log(`\n→ seeding ${CATALOG.length} listings…`);
  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer: keypair,
    options: { showEffects: true },
  });
  if (result.effects?.status?.status !== "success") {
    throw new Error(`seed tx failed: ${JSON.stringify(result.effects)}`);
  }
  await client.waitForTransaction({ digest: result.digest });
  console.log(`✓ Seeded (${result.digest})`);
  for (const spec of CATALOG) {
    console.log(
      `  ${spec.name}: ${spec.variants
        .map((v) => `${v.name} — $${v.usd}${v.loy !== null ? ` / ${v.loy} LOY` : ""}`)
        .join(", ")}`,
    );
  }
}

void main().catch((err) => {
  console.error(err);
  process.exit(1);
});
