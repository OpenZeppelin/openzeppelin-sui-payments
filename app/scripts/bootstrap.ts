/**
 * Bootstrap — end-to-end onboarding of the Move packages onto a clean chain.
 *
 *   1. Wipe stale `Published.toml` (so re-runs against a fresh localnet
 *      don't trip "package already published" errors).
 *   2. Publish in dependency order:
 *        pas  (bundles ptb via --with-unpublished-dependencies)
 *        payments  (links to the now-published pas)
 *        stablecoin-mock  (links to the same pas — critical for namespace
 *                          sharing with payments)
 *   3. Run a single PTB that:
 *        a. stablecoin_mock::setup(ns, &mut test_usd_cap)   → policy + cap
 *        b. loyalty::create(ns, loyalty_cap)                → Loyalty bundle
 *        c. config::new(...)                                → Config
 *        d. merchant::create<STABLE>(loyalty, cfg, ...)     → Merchant
 *        e. merchant::share(merchant)
 *        f. ac.grant_role × 3 (MerchantRole/CatalogManagerRole/CashierRole)
 *      and captures Merchant + loyalty Policy + stablecoin Policy IDs.
 *   4. Patch `.env.local` with every NEXT_PUBLIC_* deployment id.
 *
 * Assumes:
 *   - `sui client active-env` points at the target chain
 *   - The active address has gas (use `sui client faucet` first)
 *   - Move.toml `[environments]` declares the env name matching CLI active env
 */

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { SuiClient } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";
import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import { execSync } from "node:child_process";

type PublishObject = {
  type?: string;
  objectId: string;
  objectType?: string;
  owner?: unknown;
};

type PublishResult = {
  packageId?: string;
  createdObjects: PublishObject[];
};

const REPO_ROOT = resolve(__dirname, "..", "..");
const APP_ENV = resolve(__dirname, "..", ".env.local");

// Names of objects we care about (suffix-matched against `objectType`).
const TYPE_NAMESPACE = "::namespace::Namespace";
const TYPE_ACCESS_CONTROL = "::access_control::AccessControl<";
const TYPE_TREASURY_CAP_LOYALTY = "TreasuryCap<%PAYMENTS_PKG%::loyalty::LOYALTY>";
const TYPE_TREASURY_CAP_STABLE = "TreasuryCap<%STABLE_PKG%::stablecoin_mock::STABLECOIN_MOCK>";

function run(cmd: string, args: string[], cwd: string): string {
  const result = spawnSync(cmd, args, { cwd, encoding: "utf8" });
  if (result.status !== 0) {
    if (result.stdout) console.error(`--- stdout ---\n${result.stdout}`);
    if (result.stderr) console.error(`--- stderr ---\n${result.stderr}`);
    throw new Error(`\`${cmd} ${args.join(" ")}\` exited with code ${result.status}`);
  }
  return result.stdout;
}

function clearPublishedToml(pkgRel: string) {
  const path = resolve(REPO_ROOT, pkgRel, "Published.toml");
  if (existsSync(path)) {
    unlinkSync(path);
    console.log(`  cleared ${pkgRel}/Published.toml`);
  }
}

function publish(pkgRel: string, withUnpublished: boolean): PublishResult {
  const flag = withUnpublished ? " (bundling unpublished deps)" : "";
  console.log(`\n→ publishing ${pkgRel}${flag}`);
  const args = ["client", "publish", "--json", "--gas-budget", "1000000000"];
  if (withUnpublished) args.splice(2, 0, "--with-unpublished-dependencies");
  const out = run("sui", args, resolve(REPO_ROOT, pkgRel));
  const json = JSON.parse(out);
  const objectChanges = (json.objectChanges ?? []) as Array<Record<string, unknown>>;
  const createdObjects: PublishObject[] = objectChanges
    .filter((c) => c.type === "created")
    .map((c) => ({
      type: c.type as string,
      objectId: c.objectId as string,
      objectType: c.objectType as string | undefined,
      owner: c.owner,
    }));
  const published = objectChanges.find((c) => c.type === "published");
  return { packageId: published?.packageId as string | undefined, createdObjects };
}

function findCreated(r: PublishResult, p: (o: PublishObject) => boolean): string | null {
  return r.createdObjects.find(p)?.objectId ?? null;
}

function patchEnv(updates: Record<string, string>) {
  let raw = "";
  try {
    raw = readFileSync(APP_ENV, "utf8");
  } catch {
    /* file may not exist yet */
  }
  const lines = raw.split("\n");
  for (const [key, value] of Object.entries(updates)) {
    const idx = lines.findIndex((l) => l.startsWith(`${key}=`));
    const next = `${key}=${value}`;
    if (idx >= 0) lines[idx] = next;
    else lines.push(next);
  }
  writeFileSync(APP_ENV, lines.join("\n"), "utf8");
}

function getActiveAddress(): string {
  return execSync("sui client active-address", { encoding: "utf8" }).trim();
}

function getActiveRpcUrl(): string {
  const out = execSync("sui client envs --json", { encoding: "utf8" });
  const data = JSON.parse(out) as Array<{ alias: string; rpc: string }>[];
  const envs = data[0];
  const active = data[1] as unknown as string; // 2nd element is active env alias
  const match = envs.find((e) => e.alias === active);
  if (!match) throw new Error("could not resolve active CLI env's RPC url");
  return match.rpc;
}

/** Export the deployer's keypair from the sui keystore via `sui keytool`. */
function deployerKeypair(address: string): Ed25519Keypair {
  const out = execSync(`sui keytool export --key-identity ${address} --json`, {
    encoding: "utf8",
  });
  const parsed = JSON.parse(out) as { exportedPrivateKey: string };
  if (!parsed.exportedPrivateKey?.startsWith("suiprivkey")) {
    throw new Error(`unexpected keytool export shape: ${out.slice(0, 120)}`);
  }
  const { schema, secretKey } = decodeSuiPrivateKey(parsed.exportedPrivateKey);
  if (schema !== "ED25519") {
    throw new Error(`deployer key schema is "${schema}"; only ED25519 is supported here`);
  }
  return Ed25519Keypair.fromSecretKey(secretKey);
}

async function postPublishPTB({
  rpcUrl,
  pasPkg,
  pasUpgradeCapId,
  paymentsPkg,
  stablecoinPkg,
  stablecoinType,
  namespaceId,
  loyaltyCapId,
  stablecoinCapId,
  accessControlId,
  payoutAddress,
  deployer,
}: {
  rpcUrl: string;
  pasPkg: string;
  pasUpgradeCapId: string;
  paymentsPkg: string;
  stablecoinPkg: string;
  stablecoinType: string;
  namespaceId: string;
  loyaltyCapId: string;
  stablecoinCapId: string;
  accessControlId: string;
  payoutAddress: string;
  deployer: string;
}): Promise<{
  merchantId: string;
  loyaltyPolicyId: string;
  stablecoinPolicyId: string;
}> {
  console.log(`\n→ running post-publish PTB`);

  const keypair = deployerKeypair(deployer);

  const client = new SuiClient({ url: rpcUrl });
  const tx = new Transaction();

  // (0) pas::namespace::setup(&mut Namespace, &UpgradeCap)
  //     Links the pas Namespace singleton to its UpgradeCap — required before
  //     any policy operation (namespace::uid_mut asserts EUpgradeCapNotSet).
  tx.moveCall({
    target: `${pasPkg}::namespace::setup`,
    arguments: [tx.object(namespaceId), tx.object(pasUpgradeCapId)],
  });

  // (a) stablecoin_mock::setup(&mut Namespace, &mut TreasuryCap<STABLE>)
  //     → creates Policy<Balance<STABLE>> as shared, registers TransferApproval.
  tx.moveCall({
    target: `${stablecoinPkg}::stablecoin_mock::setup`,
    arguments: [tx.object(namespaceId), tx.object(stablecoinCapId)],
  });

  // (b) loyalty_bundle = loyalty::create(&mut Namespace, TreasuryCap<LOYALTY>)
  const loyaltyBundle = tx.moveCall({
    target: `${paymentsPkg}::loyalty::create`,
    arguments: [tx.object(namespaceId), tx.object(loyaltyCapId)],
  });

  // (c) cfg = config::new(1, 10, 1_000_000, 600_000, 600_000)
  const cfg = tx.moveCall({
    target: `${paymentsPkg}::config::new`,
    arguments: [
      tx.pure.u64(1),
      tx.pure.u64(10),
      tx.pure.u64(1_000_000),
      tx.pure.u64(600_000),
      tx.pure.u64(600_000),
    ],
  });

  // (d) merchant = merchant::create<STABLE>(loyalty, cfg, name, none, payout, ctx)
  const merchant = tx.moveCall({
    target: `${paymentsPkg}::merchant::create`,
    typeArguments: [stablecoinType],
    arguments: [
      loyaltyBundle,
      cfg,
      tx.pure.string("Demo Merchant"),
      // Option<String>::none() — encoded as an empty vector of String, length=0
      tx.pure.option("string", null),
      tx.pure.address(payoutAddress),
    ],
  });

  // (e) merchant::share(merchant)
  tx.moveCall({
    target: `${paymentsPkg}::merchant::share`,
    arguments: [merchant],
  });

  // (f) grant the deployer all three operational roles
  for (const role of ["MerchantRole", "CatalogManagerRole", "CashierRole"]) {
    tx.moveCall({
      target: `${paymentsPkg}::access_control::grant_role`,
      typeArguments: [
        `${paymentsPkg}::merchant::MERCHANT`,
        `${paymentsPkg}::merchant::${role}`,
      ],
      arguments: [tx.object(accessControlId), tx.pure.address(deployer)],
    });
  }

  tx.setGasBudget(500_000_000n);
  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer: keypair,
    options: {
      showEffects: true,
      showObjectChanges: true,
    },
  });

  if (result.effects?.status?.status !== "success") {
    throw new Error(`bootstrap PTB failed: ${JSON.stringify(result.effects)}`);
  }

  // Wait for the indexer to catch up then re-fetch to surface object changes.
  await client.waitForTransaction({ digest: result.digest });

  const created = (result.objectChanges ?? []).filter(
    (c): c is Extract<typeof c, { type: "created" }> => c.type === "created",
  );
  const merchantId = created.find((c) => c.objectType?.endsWith("::merchant::Merchant"))?.objectId;
  // pas Policy types look like `<pasPkg>::policy::Policy<...LOYALTY>` /
  // `<pasPkg>::policy::Policy<...STABLECOIN_MOCK>` — match on the type tag.
  const loyaltyPolicyId = created.find(
    (c) => c.objectType?.includes("::policy::Policy<") && c.objectType?.includes("::loyalty::LOYALTY"),
  )?.objectId;
  const stablecoinPolicyId = created.find(
    (c) =>
      c.objectType?.includes("::policy::Policy<") &&
      c.objectType?.includes("::stablecoin_mock::STABLECOIN_MOCK"),
  )?.objectId;

  if (!merchantId || !loyaltyPolicyId || !stablecoinPolicyId) {
    console.error("\nCreated objects in PTB effects:");
    for (const c of created) console.error(`  ${c.objectId} -> ${c.objectType}`);
    if (!merchantId) throw new Error("Merchant object not found in PTB effects");
    if (!loyaltyPolicyId) throw new Error("LOYALTY Policy object not found in PTB effects");
    throw new Error("STABLECOIN_MOCK Policy object not found in PTB effects");
  }

  console.log(`  Merchant            ${merchantId}`);
  console.log(`  loyalty policy      ${loyaltyPolicyId}`);
  console.log(`  stablecoin policy   ${stablecoinPolicyId}`);

  return { merchantId, loyaltyPolicyId, stablecoinPolicyId };
}

async function main() {
  // 1. Wipe stale Published.toml so we publish fresh into the active chain.
  clearPublishedToml("vendor/pas/packages/ptb");
  clearPublishedToml("vendor/pas/packages/pas");
  clearPublishedToml("contracts/payments");
  clearPublishedToml("contracts/stablecoin-mock");

  // 2. Publish in dependency order. ptb is the only Move dep with no further
  //    deps of its own, so it goes first and stands alone. Then pas (links to
  //    the now-published ptb). Then payments + stablecoin-mock — they need
  //    --with-unpublished-dependencies because their `openzeppelin_access` /
  //    `openzeppelin_math` git-resolved deps don't have on-chain publications
  //    (pas will link via its Published.toml, only the OZ packages get bundled).
  publish("vendor/pas/packages/ptb", false);

  const pas = publish("vendor/pas/packages/pas", false);
  if (!pas.packageId) throw new Error("pas publish did not return a packageId");
  const namespaceId = findCreated(
    pas,
    (o) => Boolean(o.objectType?.endsWith(TYPE_NAMESPACE)),
  );
  if (!namespaceId) throw new Error("pas publish did not create a Namespace object");
  // Each publish creates exactly one UpgradeCap, transferred to the deployer.
  const pasUpgradeCapId = findCreated(
    pas,
    (o) => o.objectType === "0x2::package::UpgradeCap",
  );
  if (!pasUpgradeCapId) throw new Error("pas publish did not create an UpgradeCap");

  const payments = publish("contracts/payments", true);
  if (!payments.packageId) throw new Error("payments publish did not return a packageId");
  const accessControlId = findCreated(
    payments,
    (o) => Boolean(o.objectType?.includes(TYPE_ACCESS_CONTROL)),
  );
  if (!accessControlId) throw new Error("payments publish did not create AccessControl");

  const stable = publish("contracts/stablecoin-mock", true);
  if (!stable.packageId) throw new Error("stablecoin-mock publish did not return packageId");

  // 3. Find the deployer-owned TreasuryCaps (transferred during init of each pkg).
  const deployer = getActiveAddress();
  const rpcUrl = getActiveRpcUrl();
  const client = new SuiClient({ url: rpcUrl });
  const { data: ownedAfter } = await client.getOwnedObjects({
    owner: deployer,
    options: { showType: true },
  });
  const expectedLoyaltyType = TYPE_TREASURY_CAP_LOYALTY.replace(
    "%PAYMENTS_PKG%",
    payments.packageId,
  );
  const expectedStableType = TYPE_TREASURY_CAP_STABLE.replace(
    "%STABLE_PKG%",
    stable.packageId,
  );
  const loyaltyCapId = ownedAfter.find((o) => o.data?.type?.includes(expectedLoyaltyType))
    ?.data?.objectId;
  const stablecoinCapId = ownedAfter.find((o) => o.data?.type?.includes(expectedStableType))
    ?.data?.objectId;
  if (!loyaltyCapId) throw new Error(`Could not find ${expectedLoyaltyType} owned by deployer`);
  if (!stablecoinCapId)
    throw new Error(`Could not find ${expectedStableType} owned by deployer`);

  const stablecoinType = `${stable.packageId}::stablecoin_mock::STABLECOIN_MOCK`;

  // 4. Run the post-publish PTB to instantiate Merchant + policies.
  const { merchantId, loyaltyPolicyId, stablecoinPolicyId } = await postPublishPTB({
    rpcUrl,
    pasPkg: pas.packageId,
    pasUpgradeCapId,
    paymentsPkg: payments.packageId,
    stablecoinPkg: stable.packageId,
    stablecoinType,
    namespaceId,
    loyaltyCapId,
    stablecoinCapId,
    accessControlId,
    payoutAddress: deployer,
    deployer,
  });

  // 5. Patch .env.local with every id.
  patchEnv({
    NEXT_PUBLIC_PACKAGE_ID: payments.packageId,
    NEXT_PUBLIC_MERCHANT_ID: merchantId,
    NEXT_PUBLIC_ACCESS_CONTROL_ID: accessControlId,
    NEXT_PUBLIC_LOYALTY_POLICY_ID: loyaltyPolicyId,
    NEXT_PUBLIC_STABLECOIN_PACKAGE_ID: stable.packageId,
    NEXT_PUBLIC_STABLECOIN_POLICY_ID: stablecoinPolicyId,
    NEXT_PUBLIC_STABLECOIN_TYPE: stablecoinType,
    NEXT_PUBLIC_NAMESPACE_ID: namespaceId,
    NEXT_PUBLIC_PAS_PACKAGE_ID: pas.packageId,
  });

  console.log(`\n✓ Bootstrap complete. .env.local patched.\n`);
  console.log(`  pas package          ${pas.packageId}`);
  console.log(`  Namespace (shared)   ${namespaceId}`);
  console.log(`  payments package     ${payments.packageId}`);
  console.log(`  stablecoin package   ${stable.packageId}`);
  console.log(`  AccessControl        ${accessControlId}`);
  console.log(`  Merchant             ${merchantId}`);
  console.log(`  loyalty policy       ${loyaltyPolicyId}`);
  console.log(`  stablecoin policy    ${stablecoinPolicyId}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
