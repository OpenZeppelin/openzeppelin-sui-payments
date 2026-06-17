/**
 * Bootstrap — end-to-end onboarding of the two payments packages onto whatever
 * network the Sui CLI is pointed at. Two code paths, picked automatically from
 * `sui client active-env`:
 *
 *   System env (testnet / mainnet)
 *   ──────────────────────────────
 *     • pas is already published on chain at its MVR-canonical address; its
 *       Namespace shared object exists and is already wired to its UpgradeCap.
 *     • Resolve pas via `mvr resolve @pas/pas`; walk pas's publish-tx for the
 *       Namespace id.
 *     • Publish payments + stablecoin-mock with `sui client publish`.
 *     • Run one PTB:
 *         stablecoin_mock::setup
 *         loyalty::create
 *         config::new
 *         merchant::create<C>(...) + merchant::share
 *         access_control::grant_role × 3
 *
 *   Anything else (localnet / ephemeral)
 *   ────────────────────────────────────
 *     • pas isn't on chain. Use `sui client test-publish --build-env testnet
 *       --publish-unpublished-deps --pubfile-path <file>`: the build resolves
 *       MVR deps to testnet bytecode, then the same bytecode is republished
 *       onto the current network alongside payments.
 *     • Find pas pkg, fresh Namespace, and pas UpgradeCap from the publish-tx
 *       objectChanges.
 *     • Republish stablecoin-mock with --pubfile-path pointing at the same
 *       file so it links to the freshly-published pas.
 *     • PTB prepends `namespace::setup(&mut ns, &UpgradeCap)` before the
 *       system-env steps to wire pas to its UpgradeCap on this fresh chain.
 *
 * The active address must hold gas. On localnet:
 *   sui start --with-faucet --force-regenesis     # in another terminal
 *   sui client switch --env local
 *   sui client faucet
 */

import { execSync, spawnSync } from "node:child_process";
import { existsSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { SuiClient } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";

type ObjectChange = Record<string, unknown>;

type PublishObject = {
  type?: string;
  objectId: string;
  objectType?: string;
  owner?: unknown;
};

type PublishedEntry = { packageId: string; modules: string[] };

type PublishResult = {
  packageId?: string;
  createdObjects: PublishObject[];
  publishedEntries: PublishedEntry[];
  objectChanges: ObjectChange[];
};

const REPO_ROOT = resolve(__dirname, "..", "..");
const APP_ENV = resolve(__dirname, "..", ".env.local");
// Shared pubfile used by every package's test-publish call. Per-package
// pubfiles would let the second publish miss pas's address from the first.
const PUBFILE_LOCAL_PATH = resolve(REPO_ROOT, "Pubfile.local.toml");

const TYPE_NAMESPACE_SUFFIX = "::namespace::Namespace";
const TYPE_AC_PREFIX = "::access_control::AccessControl<";

const SYSTEM_ENVS = new Set(["testnet", "mainnet"]);

function isSystemEnv(envAlias: string): boolean {
  return SYSTEM_ENVS.has(envAlias);
}

function run(cmd: string, args: string[], cwd: string): string {
  const result = spawnSync(cmd, args, { cwd, encoding: "utf8" });
  if (result.status !== 0) {
    if (result.stdout) console.error(`--- stdout ---\n${result.stdout}`);
    if (result.stderr) console.error(`--- stderr ---\n${result.stderr}`);
    throw new Error(`\`${cmd} ${args.join(" ")}\` exited with code ${result.status}`);
  }
  return result.stdout;
}

function clearFile(absPath: string, label: string) {
  if (existsSync(absPath)) {
    unlinkSync(absPath);
    console.log(`  cleared ${label}`);
  }
}

function publishPackage(
  pkgRel: string,
  opts: {
    testPublish?: boolean;
    pubfilePath?: string;
    buildEnv?: string;
    publishUnpublishedDeps?: boolean;
  } = {},
): PublishResult {
  const subcmd = opts.testPublish ? "test-publish" : "publish";
  console.log(`\n→ ${subcmd} ${pkgRel}`);
  const args = ["client", subcmd, "--json", "--gas-budget", "1000000000"];
  if (opts.pubfilePath) args.push("--pubfile-path", opts.pubfilePath);
  if (opts.buildEnv) args.push("--build-env", opts.buildEnv);
  if (opts.publishUnpublishedDeps) args.push("--publish-unpublished-deps");

  const out = run("sui", args, resolve(REPO_ROOT, pkgRel));
  const json = JSON.parse(out);
  const objectChanges = (json.objectChanges ?? []) as ObjectChange[];
  const createdObjects: PublishObject[] = objectChanges
    .filter((c) => c.type === "created")
    .map((c) => ({
      type: c.type as string,
      objectId: c.objectId as string,
      objectType: c.objectType as string | undefined,
      owner: c.owner,
    }));
  const publishedEntries: PublishedEntry[] = objectChanges
    .filter((c) => c.type === "published")
    .map((c) => ({
      packageId: c.packageId as string,
      modules: (c.modules as string[] | undefined) ?? [],
    }));

  // For non-test-publish, only one `published` entry exists and it's our package.
  // For test-publish with --publish-unpublished-deps, the main pkg is the entry
  // whose modules match the package name (e.g. `openzeppelin_payments`,
  // `local_mock_stablecoin`). Picking it heuristically:
  //   - prefer the entry that has `merchant` (payments) or `stablecoin_mock` (stablecoin-mock)
  //   - else fall back to the last `published` entry (deps publish before main pkg)
  const tag = pkgRel.endsWith("payments") ? "merchant" : "stablecoin_mock";
  const own =
    publishedEntries.find((e) => e.modules.includes(tag)) ??
    publishedEntries[publishedEntries.length - 1];

  return {
    packageId: own?.packageId,
    createdObjects,
    publishedEntries,
    objectChanges,
  };
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

function getActiveEnvAlias(): string {
  return execSync("sui client active-env", { encoding: "utf8" }).trim();
}

function getActiveRpcUrl(envAlias: string): string {
  const out = execSync("sui client envs --json", { encoding: "utf8" });
  const data = JSON.parse(out) as Array<{ alias: string; rpc: string }>[];
  const envs = data[0];
  const match = envs.find((e) => e.alias === envAlias);
  if (!match) throw new Error(`could not resolve RPC for env "${envAlias}"`);
  return match.rpc;
}

/**
 * System-env path — pas is already on chain. Resolve its address via MVR and
 * walk its publish-tx to find the existing Namespace shared object.
 */
async function discoverPasContextFromMVR(
  client: SuiClient,
  network: string,
): Promise<{ packageId: string; namespaceId: string }> {
  const cachedPkg = process.env.NEXT_PUBLIC_PAS_PACKAGE_ID;
  const cachedNs = process.env.NEXT_PUBLIC_NAMESPACE_ID;
  if (cachedPkg && cachedNs) {
    console.log(`  using cached pas context (pkg ${cachedPkg.slice(0, 10)}…)`);
    return { packageId: cachedPkg, namespaceId: cachedNs };
  }

  console.log(`  resolving pas via MVR for network=${network}`);
  const out = execSync("mvr resolve @pas/pas --json", {
    encoding: "utf8",
    env: { ...process.env, MVR_FALLBACK_NETWORK: network },
  });
  const mvr = JSON.parse(out) as { package_address: string };
  const packageId = mvr.package_address;

  const pkgObj = await client.getObject({
    id: packageId,
    options: { showPreviousTransaction: true },
  });
  const publishDigest = pkgObj.data?.previousTransaction;
  if (!publishDigest) throw new Error(`could not find publishing tx for pas ${packageId}`);
  const tx = await client.getTransactionBlock({
    digest: publishDigest,
    options: { showObjectChanges: true },
  });
  const ns = (tx.objectChanges ?? []).find(
    (c): c is Extract<typeof c, { type: "created" }> =>
      c.type === "created" && c.objectType?.endsWith(TYPE_NAMESPACE_SUFFIX) === true,
  );
  if (!ns) throw new Error(`could not find Namespace in pas publish tx ${publishDigest}`);
  return { packageId, namespaceId: ns.objectId };
}

function resolveMVR(name: string, network: string): string {
  const out = execSync(`mvr resolve ${name} --json`, {
    encoding: "utf8",
    env: { ...process.env, MVR_FALLBACK_NETWORK: network },
  });
  return (JSON.parse(out) as { package_address: string }).package_address;
}

function readPubfilePackageId(pubfileAbsPath: string, sourceSuffix: string): string {
  const raw = readFileSync(pubfileAbsPath, "utf8");
  const blocks = raw.split("[[published]]").slice(1);
  for (const b of blocks) {
    const src = b.match(/source\s*=\s*\{\s*local\s*=\s*"([^"]+)"/)?.[1] ?? "";
    if (src.endsWith(sourceSuffix)) {
      const pkg = b.match(/published-at\s*=\s*"(0x[0-9a-fA-F]+)"/)?.[1];
      if (pkg) return pkg;
    }
  }
  throw new Error(`no entry ending in "${sourceSuffix}" in ${pubfileAbsPath}`);
}

/**
 * Local-env path — pas was just republished by `--publish-unpublished-deps` in
 * a sub-transaction of test-publish. The Sui CLI records every published dep
 * (package id + UpgradeCap id) in the pubfile; pas's Namespace is created by
 * pas::init in that sub-tx, so we walk pas's previous-tx to find it.
 */
async function discoverPasContextFromPubfile(
  client: SuiClient,
  pubfileAbsPath: string,
): Promise<{ packageId: string; namespaceId: string; upgradeCapId: string }> {
  const raw = readFileSync(pubfileAbsPath, "utf8");
  // Split into `[[published]]` blocks and find the one whose source ends in
  // `/packages/pas`. Each block carries `published-at` + `upgrade-capability`.
  const blocks = raw.split("[[published]]").slice(1);
  let pasBlock: string | undefined;
  for (const b of blocks) {
    const src = b.match(/source\s*=\s*\{\s*local\s*=\s*"([^"]+)"/)?.[1] ?? "";
    if (src.endsWith("/packages/pas")) {
      pasBlock = b;
      break;
    }
  }
  if (!pasBlock) throw new Error(`could not find pas entry in ${pubfileAbsPath}`);

  const packageId = pasBlock.match(/published-at\s*=\s*"(0x[0-9a-fA-F]+)"/)?.[1];
  const upgradeCapId = pasBlock.match(/upgrade-capability\s*=\s*"(0x[0-9a-fA-F]+)"/)?.[1];
  if (!packageId || !upgradeCapId) {
    throw new Error(`pas block in pubfile is missing published-at or upgrade-capability`);
  }

  // Walk pas's publish tx to find its fresh Namespace shared object.
  const pkgObj = await client.getObject({
    id: packageId,
    options: { showPreviousTransaction: true },
  });
  const publishDigest = pkgObj.data?.previousTransaction;
  if (!publishDigest) throw new Error(`could not find publish tx for pas ${packageId}`);
  const tx = await client.getTransactionBlock({
    digest: publishDigest,
    options: { showObjectChanges: true },
  });
  const ns = (tx.objectChanges ?? []).find(
    (c): c is Extract<typeof c, { type: "created" }> =>
      c.type === "created" && c.objectType?.endsWith(TYPE_NAMESPACE_SUFFIX) === true,
  );
  if (!ns) throw new Error(`could not find Namespace in pas publish tx ${publishDigest}`);

  return { packageId, namespaceId: ns.objectId, upgradeCapId };
}

function deployerKeypair(address: string): Ed25519Keypair {
  const out = execSync(`sui keytool export --key-identity ${address} --json`, {
    encoding: "utf8",
  });
  const parsed = JSON.parse(out) as { exportedPrivateKey: string };
  // fromSecretKey accepts a bech32 string directly and throws if the
  // embedded schema is not ED25519.
  return Ed25519Keypair.fromSecretKey(parsed.exportedPrivateKey);
}

async function postPublishPTB({
  rpcUrl,
  pasPkg,
  ozAccessPkg,
  paymentsPkg,
  stablecoinPkg,
  stablecoinType,
  namespaceId,
  loyaltyCapId,
  stablecoinCapId,
  accessControlId,
  payoutAddress,
  deployer,
  pasUpgradeCapId,
}: {
  rpcUrl: string;
  pasPkg: string;
  ozAccessPkg: string;
  paymentsPkg: string;
  stablecoinPkg: string;
  stablecoinType: string;
  namespaceId: string;
  loyaltyCapId: string;
  stablecoinCapId: string;
  accessControlId: string;
  payoutAddress: string;
  deployer: string;
  pasUpgradeCapId?: string;
}): Promise<{
  merchantId: string;
  loyaltyPolicyId: string;
  stablecoinPolicyId: string;
}> {
  console.log(`\n→ running post-publish PTB`);

  const keypair = deployerKeypair(deployer);
  const client = new SuiClient({ url: rpcUrl });
  const tx = new Transaction();

  // (0) On a fresh chain only — wire pas's Namespace to its UpgradeCap.
  // On testnet/mainnet pas is already published and this step has already run.
  if (pasUpgradeCapId) {
    tx.moveCall({
      target: `${pasPkg}::namespace::setup`,
      arguments: [tx.object(namespaceId), tx.object(pasUpgradeCapId)],
    });
  }

  // (a) stablecoin_mock::setup(&mut Namespace, &mut TreasuryCap<STABLE>)
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
      tx.pure.option("string", null),
      tx.pure.address(payoutAddress),
    ],
  });
  // (e) merchant::share(merchant)
  tx.moveCall({ target: `${paymentsPkg}::merchant::share`, arguments: [merchant] });

  // (f) grant the deployer all three operational roles. grant_role lives in
  // openzeppelin_access::access_control, so target the OZ package, not ours.
  for (const role of ["MerchantRole", "CatalogManagerRole", "CashierRole"]) {
    tx.moveCall({
      target: `${ozAccessPkg}::access_control::grant_role`,
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
    options: { showEffects: true, showObjectChanges: true },
  });

  if (result.effects?.status?.status !== "success") {
    throw new Error(`bootstrap PTB failed: ${JSON.stringify(result.effects)}`);
  }
  await client.waitForTransaction({ digest: result.digest });

  const created = (result.objectChanges ?? []).filter(
    (c): c is Extract<typeof c, { type: "created" }> => c.type === "created",
  );
  const merchantId = created.find((c) =>
    c.objectType?.endsWith("::merchant::Merchant"),
  )?.objectId;
  const loyaltyPolicyId = created.find(
    (c) =>
      c.objectType?.includes("::policy::Policy<") &&
      c.objectType?.includes("::loyalty::LOYALTY"),
  )?.objectId;
  const stablecoinPolicyId = created.find(
    (c) =>
      c.objectType?.includes("::policy::Policy<") &&
      c.objectType?.includes("::stablecoin_mock::STABLECOIN_MOCK"),
  )?.objectId;

  if (!merchantId || !loyaltyPolicyId || !stablecoinPolicyId) {
    console.error("\nCreated objects:");
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
  const envAlias = getActiveEnvAlias();
  const rpcUrl = getActiveRpcUrl(envAlias);
  const deployer = getActiveAddress();
  const client = new SuiClient({ url: rpcUrl });
  const ephemeral = !isSystemEnv(envAlias);

  console.log(`active env: ${envAlias} (${rpcUrl})  ${ephemeral ? "[ephemeral]" : ""}`);
  console.log(`active address: ${deployer}`);

  let pasPackageId: string;
  let namespaceId: string;
  let pasUpgradeCapId: string | undefined;
  let ozAccessPkg: string;
  let payments: PublishResult;
  let stable: PublishResult;
  let accessControlId: string | null;

  if (ephemeral) {
    // ─── local / ephemeral chain ───────────────────────────────────────────
    // Fresh chain each genesis → clear the local pubfile so test-publish
    // re-publishes pas + OZ deps from scratch instead of pointing at addresses
    // from a previous chain. Both packages share one absolute pubfile so the
    // second publish sees pas's freshly-published address from the first.
    clearFile(PUBFILE_LOCAL_PATH, PUBFILE_LOCAL_PATH);
    clearFile(
      resolve(REPO_ROOT, "contracts/payments/Published.toml"),
      "contracts/payments/Published.toml",
    );
    clearFile(
      resolve(REPO_ROOT, "contracts/stablecoin-mock/Published.toml"),
      "contracts/stablecoin-mock/Published.toml",
    );

    // Publish payments with --publish-unpublished-deps so pas + ptb + OZ get
    // republished here. Build against testnet's MVR records.
    payments = publishPackage("contracts/payments", {
      testPublish: true,
      pubfilePath: PUBFILE_LOCAL_PATH,
      buildEnv: "testnet",
      publishUnpublishedDeps: true,
    });
    if (!payments.packageId) throw new Error("payments publish returned no packageId");

    accessControlId = findCreated(payments, (o) =>
      Boolean(o.objectType?.includes(TYPE_AC_PREFIX)),
    );
    if (!accessControlId) throw new Error("payments publish did not create AccessControl");

    // Mine pas info out of the pubfile (pas was published as a sub-tx of
    // test-publish; its package id + UpgradeCap id live in Pubfile.local.toml).
    const pasCtx = await discoverPasContextFromPubfile(client, PUBFILE_LOCAL_PATH);
    pasPackageId = pasCtx.packageId;
    namespaceId = pasCtx.namespaceId;
    pasUpgradeCapId = pasCtx.upgradeCapId;

    // Stablecoin-mock now links to the freshly-published pas via the same pubfile.
    stable = publishPackage("contracts/stablecoin-mock", {
      testPublish: true,
      pubfilePath: PUBFILE_LOCAL_PATH,
      buildEnv: "testnet",
    });
    if (!stable.packageId) throw new Error("stablecoin-mock publish returned no packageId");

    ozAccessPkg = readPubfilePackageId(PUBFILE_LOCAL_PATH, "/contracts/access");
  } else {
    // ─── testnet / mainnet ─────────────────────────────────────────────────
    const ctx = await discoverPasContextFromMVR(client, envAlias);
    pasPackageId = ctx.packageId;
    namespaceId = ctx.namespaceId;
    ozAccessPkg = resolveMVR("@openzeppelin-move/access", envAlias);

    clearFile(
      resolve(REPO_ROOT, "contracts/payments/Published.toml"),
      "contracts/payments/Published.toml",
    );
    clearFile(
      resolve(REPO_ROOT, "contracts/stablecoin-mock/Published.toml"),
      "contracts/stablecoin-mock/Published.toml",
    );

    payments = publishPackage("contracts/payments");
    if (!payments.packageId) throw new Error("payments publish returned no packageId");
    accessControlId = findCreated(payments, (o) =>
      Boolean(o.objectType?.includes(TYPE_AC_PREFIX)),
    );
    if (!accessControlId) throw new Error("payments publish did not create AccessControl");

    stable = publishPackage("contracts/stablecoin-mock");
    if (!stable.packageId) throw new Error("stablecoin-mock publish returned no packageId");
  }

  console.log(`  pas package    ${pasPackageId}`);
  console.log(`  Namespace      ${namespaceId}`);
  if (pasUpgradeCapId) console.log(`  pas UpgradeCap ${pasUpgradeCapId}`);

  // Discover deployer-owned TreasuryCaps after both publishes.
  const { data: ownedAfter } = await client.getOwnedObjects({
    owner: deployer,
    options: { showType: true },
  });
  const wantLoyalty = `TreasuryCap<${payments.packageId}::loyalty::LOYALTY>`;
  const wantStable = `TreasuryCap<${stable.packageId}::stablecoin_mock::STABLECOIN_MOCK>`;
  const loyaltyCapId = ownedAfter.find((o) => o.data?.type?.includes(wantLoyalty))?.data?.objectId;
  const stablecoinCapId = ownedAfter.find((o) => o.data?.type?.includes(wantStable))?.data
    ?.objectId;
  if (!loyaltyCapId) throw new Error(`Could not find ${wantLoyalty} owned by deployer`);
  if (!stablecoinCapId) throw new Error(`Could not find ${wantStable} owned by deployer`);

  const stablecoinType = `${stable.packageId}::stablecoin_mock::STABLECOIN_MOCK`;

  const { merchantId, loyaltyPolicyId, stablecoinPolicyId } = await postPublishPTB({
    rpcUrl,
    pasPkg: pasPackageId,
    ozAccessPkg,
    paymentsPkg: payments.packageId!,
    stablecoinPkg: stable.packageId!,
    stablecoinType,
    namespaceId,
    loyaltyCapId,
    stablecoinCapId,
    accessControlId: accessControlId!,
    payoutAddress: deployer,
    deployer,
    pasUpgradeCapId,
  });

  patchEnv({
    NEXT_PUBLIC_PACKAGE_ID: payments.packageId!,
    NEXT_PUBLIC_MERCHANT_ID: merchantId,
    NEXT_PUBLIC_ACCESS_CONTROL_ID: accessControlId!,
    NEXT_PUBLIC_LOYALTY_POLICY_ID: loyaltyPolicyId,
    NEXT_PUBLIC_STABLECOIN_PACKAGE_ID: stable.packageId!,
    NEXT_PUBLIC_STABLECOIN_POLICY_ID: stablecoinPolicyId,
    NEXT_PUBLIC_STABLECOIN_TYPE: stablecoinType,
    NEXT_PUBLIC_NAMESPACE_ID: namespaceId,
    NEXT_PUBLIC_PAS_PACKAGE_ID: pasPackageId,
    NEXT_PUBLIC_OZ_ACCESS_PACKAGE_ID: ozAccessPkg,
  });

  console.log(`\n✓ Bootstrap complete. .env.local patched.\n`);
  console.log(`  pas package          ${pasPackageId}`);
  console.log(`  Namespace            ${namespaceId}`);
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
