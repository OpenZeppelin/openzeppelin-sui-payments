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
import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import { SuiClient } from "@mysten/sui/client";
import { getFaucetHost, requestSuiFromFaucetV2 } from "@mysten/sui/faucet";
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
const APP_DIR = resolve(__dirname, "..");
/** The Next.js dev server reads `.env.local`; we keep it as a mirror of
 *  whichever per-network `.env.<network>` is currently active. */
const LOCAL_ENV = resolve(APP_DIR, ".env.local");
/** Per-network source-of-truth file bootstrap reads/writes. Set once the
 *  active network is known (from the CLI arg or `sui client active-env`);
 *  `patchEnv` and `readEnvFile` operate against this path exclusively. */
let TARGET_ENV: string = LOCAL_ENV;

function envFileForNetwork(network: string): string {
  const normalized = network === "local" ? "localnet" : network;
  return resolve(APP_DIR, `.env.${normalized}`);
}
// Shared pubfile used by every package's test-publish call. Per-package
// pubfiles would let the second publish miss pas's address from the first.
const PUBFILE_LOCAL_PATH = resolve(REPO_ROOT, "Pubfile.local.toml");

const TYPE_NAMESPACE_SUFFIX = "::namespace::Namespace";
const TYPE_AC_PREFIX = "::access_control::AccessControl<";

const SYSTEM_ENVS = new Set(["testnet", "mainnet"]);

function isSystemEnv(envAlias: string): boolean {
  return SYSTEM_ENVS.has(envAlias);
}

/// Canonical chain identifiers returned by `sui_getChainIdentifier`. Stable across
/// upgrades of the framework; used to verify that the CLI alias the user picked
/// actually points at the chain they think it does. Without this check, an alias
/// renamed `"testnet"` that resolves to devnet — or a local alias that happens to
/// resolve to real testnet — would silently take the wrong bootstrap branch.
const KNOWN_NETWORK_IDS = {
  mainnet: "35834a8a",
  testnet: "4c78adac",
} as const;

async function assertEnvMatchesChain(
  client: SuiClient,
  envAlias: string,
): Promise<void> {
  const chainId = await client.getChainIdentifier();

  // Alias claims a canonical network — the chain must match.
  if (envAlias === "mainnet" && chainId !== KNOWN_NETWORK_IDS.mainnet) {
    throw new Error(
      `CLI alias "mainnet" resolves to chain ${chainId}, not the canonical Sui ` +
        `mainnet (${KNOWN_NETWORK_IDS.mainnet}). Refusing to bootstrap with this ` +
        `misconfiguration — your alias points somewhere else.`,
    );
  }
  if (envAlias === "testnet" && chainId !== KNOWN_NETWORK_IDS.testnet) {
    throw new Error(
      `CLI alias "testnet" resolves to chain ${chainId}, not the canonical Sui ` +
        `testnet (${KNOWN_NETWORK_IDS.testnet}). Refusing to bootstrap with this ` +
        `misconfiguration — your alias points somewhere else.`,
    );
  }

  // Alias is anything else (treated as ephemeral) but the chain is canonical —
  // refuse, so we don't accidentally run `test-publish` against real testnet/mainnet.
  if (!isSystemEnv(envAlias)) {
    if (chainId === KNOWN_NETWORK_IDS.mainnet) {
      throw new Error(
        `CLI alias "${envAlias}" resolves to Sui mainnet (${chainId}). Bootstrap ` +
          `would treat this as ephemeral and run test-publish — refusing. Rename ` +
          `the alias to "mainnet" if this is intentional.`,
      );
    }
    if (chainId === KNOWN_NETWORK_IDS.testnet) {
      throw new Error(
        `CLI alias "${envAlias}" resolves to Sui testnet (${chainId}). Bootstrap ` +
          `would treat this as ephemeral and run test-publish — refusing. Rename ` +
          `the alias to "testnet" if this is intentional.`,
      );
    }
  }
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

/**
 * Read a single `KEY=value` line from `.env.local` without loading any dotenv
 * machinery. Used by `resolveSponsorKeypair` so the local gas-station key
 * survives a re-bootstrap (the funded sponsor address stays stable across runs).
 */
function readEnvFile(key: string): string | undefined {
  let raw = "";
  try {
    raw = readFileSync(TARGET_ENV, "utf8");
  } catch {
    return undefined;
  }
  const prefix = `${key}=`;
  const line = raw.split("\n").find((l) => l.startsWith(prefix));
  if (!line) return undefined;
  return line.slice(prefix.length).trim();
}

function patchEnv(updates: Record<string, string>) {
  let raw = "";
  try {
    raw = readFileSync(TARGET_ENV, "utf8");
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
  writeFileSync(TARGET_ENV, lines.join("\n"), "utf8");
}

function getActiveAddress(): string {
  return execSync("sui client active-address", { encoding: "utf8" }).trim();
}

function getActiveEnvAlias(): string {
  return execSync("sui client active-env", { encoding: "utf8" }).trim();
}

/**
 * Optional CLI arg — `pnpm bootstrap <network>` shorthand. Accepts
 * `localnet`/`testnet`/`mainnet`; anything else returns null (fall back to
 * whatever `sui client active-env` is set to). Side effects when set:
 *   1. `sui client switch --env <alias>` so the CLI targets the right chain
 *      (with a `local` fallback since Sui CLI's default localnet alias name
 *      varies between installs).
 *   2. `NEXT_PUBLIC_SUI_NETWORK=<network>` written to `.env.local` so the
 *      dev server matches on next start.
 */
function applyNetworkFromArgv(): "localnet" | "testnet" | "mainnet" | null {
  const arg = process.argv[2];
  if (!arg) return null;
  if (arg !== "localnet" && arg !== "testnet" && arg !== "mainnet") {
    throw new Error(
      `unknown network arg "${arg}" — expected one of localnet | testnet | mainnet`,
    );
  }
  const tryAliases = arg === "localnet" ? ["localnet", "local"] : [arg];
  let switched: string | null = null;
  for (const alias of tryAliases) {
    try {
      execSync(`sui client switch --env ${alias}`, { encoding: "utf8", stdio: "pipe" });
      switched = alias;
      break;
    } catch {
      // try next alias
    }
  }
  if (!switched) {
    throw new Error(
      `sui client has no env alias matching ${tryAliases.join(" or ")}. ` +
        `Add one with \`sui client new-env --alias ${arg} --rpc <url>\` first.`,
    );
  }
  TARGET_ENV = envFileForNetwork(arg);
  console.log(`→ switched sui client to env "${switched}" (from CLI arg)`);
  patchEnv({ NEXT_PUBLIC_SUI_NETWORK: arg });
  console.log(`→ target env file: ${TARGET_ENV}`);
  return arg;
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
  // tsx doesn't auto-load `.env.local` — fall back to reading the file so a
  // dev who pinned these values there doesn't need to shell-export them too.
  const cachedPkg =
    process.env.NEXT_PUBLIC_PAS_PACKAGE_ID ?? readEnvFile("NEXT_PUBLIC_PAS_PACKAGE_ID");
  const cachedNs =
    process.env.NEXT_PUBLIC_NAMESPACE_ID ?? readEnvFile("NEXT_PUBLIC_NAMESPACE_ID");
  if (cachedPkg && cachedNs) {
    console.log(`  using cached pas context (pkg ${cachedPkg.slice(0, 10)}…)`);
    return { packageId: cachedPkg, namespaceId: cachedNs };
  }

  console.log(`  resolving pas via MVR for network=${network}`);
  const out = execSync("mvr resolve @pas/pas --json", {
    encoding: "utf8",
    env: { ...process.env, MVR_FALLBACK_NETWORK: network },
  });
  const mvr = JSON.parse(out) as { Resolve: { package_address: string } };
  const packageId = mvr.Resolve.package_address;

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
  return (JSON.parse(out) as { Resolve: { package_address: string } }).Resolve
    .package_address;
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
  return Ed25519Keypair.fromSecretKey(deployerPrivateKey(address));
}

function deployerPrivateKey(address: string): string {
  const out = execSync(`sui keytool export --key-identity ${address} --json`, {
    encoding: "utf8",
  });
  return (JSON.parse(out) as { exportedPrivateKey: string }).exportedPrivateKey;
}

/**
 * Resolve a stable sponsor keypair for the localnet gas-station route
 * (`/api/sponsor`). Reuses `SPONSOR_PRIVATE_KEY` from `.env.local` when present
 * so the funded sponsor address survives a re-bootstrap; otherwise mints a
 * fresh ed25519 key. Caller is responsible for funding it via the faucet.
 *
 * Localnet only — on testnet/mainnet sponsorship is handled by Enoki via the
 * connected wallet, and no server-side sponsor key is provisioned.
 */
function resolveSponsorKeypair(): { keypair: Ed25519Keypair; privateKey: string } {
  // tsx doesn't auto-load `.env.local`, so process.env is empty here even if the
  // file has a value. Read the file directly as a fallback before generating
  // anything new.
  const existing =
    process.env.SPONSOR_PRIVATE_KEY ?? readEnvFile("SPONSOR_PRIVATE_KEY");
  if (existing && existing.length > 0) {
    const { schema, secretKey } = decodeSuiPrivateKey(existing);
    if (schema === "ED25519") {
      const keypair = Ed25519Keypair.fromSecretKey(secretKey);
      return { keypair, privateKey: existing };
    }
    console.warn(
      `  SPONSOR_PRIVATE_KEY schema is "${schema}"; regenerating an ed25519 key.`,
    );
  }
  const keypair = new Ed25519Keypair();
  return { keypair, privateKey: keypair.getSecretKey() };
}

async function fundFromLocalFaucet(address: string): Promise<void> {
  await requestSuiFromFaucetV2({
    host: getFaucetHost("localnet"),
    recipient: address,
  });
}

/**
 * On a fresh chain only — wire pas's Namespace to its UpgradeCap and
 * create the shared `Templates` registry. Must run in its own transaction
 * because `templates::setup` shares the object directly, so its id isn't
 * available within the same PTB.
 */
async function setupPasOnFreshChain(
  client: SuiClient,
  keypair: Ed25519Keypair,
  pasPkg: string,
  namespaceId: string,
  pasUpgradeCapId: string,
  payoutAddress: string,
): Promise<{ templatesId: string }> {
  console.log(`\n→ pas init (namespace::setup + templates::setup + merchant payout account)`);
  const tx = new Transaction();
  tx.moveCall({
    target: `${pasPkg}::namespace::setup`,
    arguments: [tx.object(namespaceId), tx.object(pasUpgradeCapId)],
  });
  tx.moveCall({
    target: `${pasPkg}::templates::setup`,
    arguments: [tx.object(namespaceId)],
  });
  // Pre-create the merchant's payout PAS account so customer-side `pay` flows
  // can take it as `&Account` without an extra setup hop.
  tx.moveCall({
    target: `${pasPkg}::account::create_and_share`,
    arguments: [tx.object(namespaceId), tx.pure.address(payoutAddress)],
  });
  tx.setGasBudget(200_000_000n);
  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer: keypair,
    options: { showEffects: true, showObjectChanges: true },
  });
  if (result.effects?.status?.status !== "success") {
    throw new Error(`pas init tx failed: ${JSON.stringify(result.effects)}`);
  }
  await client.waitForTransaction({ digest: result.digest });

  const templates = (result.objectChanges ?? []).find(
    (c): c is Extract<typeof c, { type: "created" }> =>
      c.type === "created" && c.objectType?.endsWith("::templates::Templates") === true,
  );
  if (!templates) throw new Error("could not find Templates shared object in pas init tx");
  console.log(`  Templates       ${templates.objectId}`);
  return { templatesId: templates.objectId };
}

/**
 * Promotes the publish-time `Currency<STABLECOIN_MOCK>` from its TTO state under
 * `CoinRegistry` (@0xc) to a derived-address shared object via
 * `coin_registry::finalize_registration<C>`. Returns the id of the now-shared
 * Currency, discovered from the tx's `objectChanges`.
 */
async function finalizeStablecoinCurrency({
  client,
  keypair,
  ttoCurrencyId,
  stablecoinType,
}: {
  client: SuiClient;
  keypair: Ed25519Keypair;
  ttoCurrencyId: string;
  stablecoinType: string;
}): Promise<string> {
  console.log(`\n→ finalizing Currency<${stablecoinType}>`);

  const ttoObject = await client.getObject({
    id: ttoCurrencyId,
    options: { showOwner: true },
  });
  if (!ttoObject.data) {
    throw new Error(`Could not fetch TTO Currency ${ttoCurrencyId}`);
  }
  const tx = new Transaction();
  tx.moveCall({
    target: `0x2::coin_registry::finalize_registration`,
    typeArguments: [stablecoinType],
    arguments: [
      tx.object("0xc"),
      tx.receivingRef({
        objectId: ttoCurrencyId,
        version: ttoObject.data.version,
        digest: ttoObject.data.digest,
      }),
    ],
  });
  tx.setGasBudget(100_000_000n);
  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer: keypair,
    options: { showEffects: true, showObjectChanges: true },
  });
  if (result.effects?.status?.status !== "success") {
    throw new Error(`finalize_registration failed: ${JSON.stringify(result.effects)}`);
  }
  await client.waitForTransaction({ digest: result.digest });

  const created = (result.objectChanges ?? []).filter(
    (c): c is Extract<typeof c, { type: "created" }> => c.type === "created",
  );
  const sharedCurrency = created.find((c) =>
    c.objectType?.includes(`::coin_registry::Currency<${stablecoinType}>`),
  );
  if (!sharedCurrency) {
    throw new Error("finalize_registration did not produce a shared Currency");
  }
  console.log(`  shared Currency  ${sharedCurrency.objectId}`);
  return sharedCurrency.objectId;
}

async function postPublishPTB({
  rpcUrl,
  pasPkg,
  ozAccessPkg,
  paymentsPkg,
  stablecoinPkg,
  stablecoinType,
  stablecoinCurrencyId,
  namespaceId,
  templatesId,
  loyaltyCapId,
  stablecoinCapId,
  accessControlId,
  payoutAddress,
  deployer,
}: {
  rpcUrl: string;
  pasPkg: string;
  ozAccessPkg: string;
  paymentsPkg: string;
  stablecoinPkg: string;
  stablecoinType: string;
  stablecoinCurrencyId: string;
  namespaceId: string;
  templatesId: string;
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

  // (a) stablecoin_mock::setup(&mut Namespace, &mut TreasuryCap<STABLE>, &mut Templates, ctx)
  tx.moveCall({
    target: `${stablecoinPkg}::stablecoin_mock::setup`,
    arguments: [
      tx.object(namespaceId),
      tx.object(stablecoinCapId),
      tx.object(templatesId),
    ],
  });

  // (b) loyalty_bundle = loyalty::create(&mut Namespace, TreasuryCap<LOYALTY>)
  const loyaltyBundle = tx.moveCall({
    target: `${paymentsPkg}::loyalty::create`,
    arguments: [tx.object(namespaceId), tx.object(loyaltyCapId)],
  });

  // (c) cfg = config::new<STABLE>(&Currency<STABLE>, payout, 1e9 ("1.0"), 1_000_000, 600_000, 600_000)
  const cfg = tx.moveCall({
    target: `${paymentsPkg}::config::new`,
    typeArguments: [stablecoinType],
    arguments: [
      tx.object(stablecoinCurrencyId),
      tx.pure.address(payoutAddress),
      // `LOYALTY_FLOAT_SCALING` — 1 LOY per stablecoin unit.
      tx.pure.u64(1_000_000_000n),
      tx.pure.u64(1_000_000n),
      tx.pure.u64(600_000n),
      tx.pure.u64(600_000n),
    ],
  });

  // (d) merchant = merchant::create(loyalty, cfg, name, none, ctx)
  // `create` is no longer generic on the coin and no longer takes `payout_address`
  // — both are pinned through Config above.
  const merchant = tx.moveCall({
    target: `${paymentsPkg}::merchant::create`,
    arguments: [
      loyaltyBundle,
      cfg,
      tx.pure.string("Demo Merchant"),
      tx.pure.option("string", null),
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
  const fromArg = applyNetworkFromArgv();
  const envAlias = getActiveEnvAlias();
  // Fallback when no CLI arg was passed: derive the target env file from the
  // sui client's active env. `local` and `localnet` both map to `.env.localnet`.
  if (!fromArg) {
    TARGET_ENV = envFileForNetwork(envAlias);
  }
  const rpcUrl = getActiveRpcUrl(envAlias);
  const deployer = getActiveAddress();
  const client = new SuiClient({ url: rpcUrl });

  // Verify the CLI alias actually points where it claims. `sui client active-env`
  // is a user-defined label, not an identity check — without this guard a
  // renamed alias can flip the bootstrap branch silently.
  await assertEnvMatchesChain(client, envAlias);

  const ephemeral = !isSystemEnv(envAlias);

  console.log(`active env: ${envAlias} (${rpcUrl})  ${ephemeral ? "[ephemeral]" : ""}`);
  console.log(`active address: ${deployer}`);

  let pasPackageId: string;
  let namespaceId: string;
  let pasUpgradeCapId: string | undefined;
  let ozAccessPkg: string;
  let templatesId: string | undefined;
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

    // pas was just published — bootstrap it: link the UpgradeCap and create
    // the shared `Templates` registry. `templates::setup` shares its result,
    // so this must run in its own tx before the post-publish PTB consumes the
    // Templates id (for stablecoin_mock::setup).
    const pasInit = await setupPasOnFreshChain(
      client,
      deployerKeypair(deployer),
      pasPackageId,
      namespaceId,
      pasUpgradeCapId!,
      deployer,
    );
    templatesId = pasInit.templatesId;
  } else {
    // ─── testnet / mainnet ─────────────────────────────────────────────────
    const ctx = await discoverPasContextFromMVR(client, envAlias);
    pasPackageId = ctx.packageId;
    namespaceId = ctx.namespaceId;
    ozAccessPkg = resolveMVR("@openzeppelin-move/access", envAlias);

    // pas on canonical networks should already have `Templates` initialized.
    // We can't easily discover it from the publish tx (Templates is created by
    // a separate `templates::setup` call, not by pas::init), so for now we
    // expect it to be supplied via env. TODO: derive via derived_object math.
    templatesId =
      process.env.NEXT_PUBLIC_TEMPLATES_ID ?? readEnvFile("NEXT_PUBLIC_TEMPLATES_ID");
    if (!templatesId) {
      throw new Error(
        "NEXT_PUBLIC_TEMPLATES_ID is required on testnet/mainnet — set it to the " +
          "id of the pas::templates::Templates shared object for this network",
      );
    }

    // Reuse an existing deployment when `.env.local` already records one.
    // Bootstrap wrote `NEXT_PUBLIC_MERCHANT_ID` after the last successful
    // publish, so its presence is our "already deployed" signal — running
    // publish again would only orphan the previous packages on chain.
    //
    // To force a fresh publish (e.g. after changing a contract), delete the
    // two Published.toml files and clear the deployment-id NEXT_PUBLIC_* lines
    // in .env.local. If Published.toml still records a deployment but env is
    // cleared, `sui client publish` will error clearly on its own with
    // "already published on this environment — use `sui client upgrade`".
    const existingMerchant =
      process.env.NEXT_PUBLIC_MERCHANT_ID ?? readEnvFile("NEXT_PUBLIC_MERCHANT_ID");
    if (existingMerchant) {
      console.log(
        `\n✓ ${envAlias}: reusing existing deployment (merchant ${existingMerchant.slice(0, 10)}…).`,
      );
      console.log(
        `  To force a fresh publish: delete contracts/payments/Published.toml, ` +
          `contracts/stablecoin-mock/Published.toml, and clear the NEXT_PUBLIC_* ` +
          `deployment ids in .env.local, then re-run.`,
      );
      return;
    }

    payments = publishPackage("contracts/payments");
    if (!payments.packageId) throw new Error("payments publish returned no packageId");
    accessControlId = findCreated(payments, (o) =>
      Boolean(o.objectType?.includes(TYPE_AC_PREFIX)),
    );
    if (!accessControlId) throw new Error("payments publish did not create AccessControl");

    stable = publishPackage("contracts/stablecoin-mock");
    if (!stable.packageId) throw new Error("stablecoin-mock publish returned no packageId");

    // Merchant payout PAS account. On localnet this is created inside
    // `setupPasOnFreshChain`; on testnet/mainnet we do it here so the
    // customer-side `pay` flow can take the payout `&Account` without an
    // extra manual init hop. Pre-check via dev-inspect so we don't hit the
    // `EAccountAlreadyExists` abort on re-runs — the derived address is
    // stable per (namespace, payout_address), so re-bootstraps with the
    // same deployer land on the same account. Any other failure propagates.
    const probe = new Transaction();
    probe.moveCall({
      target: `${pasPackageId}::namespace::account_exists`,
      arguments: [probe.object(namespaceId), probe.pure.address(deployer)],
    });
    const probeResult = await client.devInspectTransactionBlock({
      sender: deployer,
      transactionBlock: probe,
    });
    if (probeResult.effects?.status?.status !== "success") {
      throw new Error(
        `namespace::account_exists probe failed: ${probeResult.effects?.status?.error ?? "unknown"}`,
      );
    }
    const alreadyExists =
      probeResult.results?.[0]?.returnValues?.[0]?.[0]?.[0] === 1;

    if (alreadyExists) {
      console.log(`\n✓ payout PAS account for ${deployer} already exists — reusing.`);
    } else {
      console.log(`\n→ creating payout PAS account for ${deployer}`);
      const tx = new Transaction();
      tx.moveCall({
        target: `${pasPackageId}::account::create_and_share`,
        arguments: [tx.object(namespaceId), tx.pure.address(deployer)],
      });
      tx.setGasBudget(50_000_000n);
      const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: deployerKeypair(deployer),
        options: { showEffects: true },
      });
      if (result.effects?.status?.status !== "success") {
        throw new Error(
          `payout account creation failed: ${result.effects?.status?.error ?? "unknown"}`,
        );
      }
      await client.waitForTransaction({ digest: result.digest });
      console.log(`  payout account created (${result.digest})`);
    }
  }

  console.log(`  pas package    ${pasPackageId}`);
  console.log(`  Namespace      ${namespaceId}`);
  if (pasUpgradeCapId) console.log(`  pas UpgradeCap ${pasUpgradeCapId}`);

  // Discover deployer-owned TreasuryCaps after both publishes. Page-walk so
  // the lookup doesn't depend on both caps landing on the first page (deployers
  // with many owned objects would otherwise miss one or both).
  const wantLoyalty = `TreasuryCap<${payments.packageId}::loyalty::LOYALTY>`;
  const wantStable = `TreasuryCap<${stable.packageId}::stablecoin_mock::STABLECOIN_MOCK>`;
  let loyaltyCapId: string | undefined;
  let stablecoinCapId: string | undefined;
  let cursor: string | null = null;
  do {
    const page = await client.getOwnedObjects({
      owner: deployer,
      options: { showType: true },
      cursor: cursor ?? undefined,
    });
    for (const o of page.data) {
      const t = o.data?.type;
      const id = o.data?.objectId;
      if (!t || !id) continue;
      if (!loyaltyCapId && t.includes(wantLoyalty)) loyaltyCapId = id;
      else if (!stablecoinCapId && t.includes(wantStable)) stablecoinCapId = id;
      if (loyaltyCapId && stablecoinCapId) break;
    }
    if (loyaltyCapId && stablecoinCapId) break;
    cursor = page.hasNextPage ? (page.nextCursor ?? null) : null;
  } while (cursor);
  if (!loyaltyCapId) throw new Error(`Could not find ${wantLoyalty} owned by deployer`);
  if (!stablecoinCapId) throw new Error(`Could not find ${wantStable} owned by deployer`);

  const stablecoinType = `${stable.packageId}::stablecoin_mock::STABLECOIN_MOCK`;

  // `stablecoin_mock::init` runs the OTW path of `coin_registry::new_currency_with_otw`,
  // which transfers the `Currency<STABLECOIN_MOCK>` to the system `CoinRegistry`
  // (@0xc) as a TTO — NOT a shared object. We have to run `finalize_registration`
  // in its own tx before the post-publish PTB can reference the Currency as a
  // shared input (PTBs can't reference an object that's only shared mid-execution).
  const stablecoinCurrencyType = `Currency<${stablecoinType}>`;
  const ttoCurrencyId = findCreated(stable, (o) =>
    Boolean(
      o.objectType?.includes("::coin_registry::") &&
        o.objectType?.includes(stablecoinCurrencyType),
    ),
  );
  if (!ttoCurrencyId) {
    throw new Error(`Could not find ${stablecoinCurrencyType} in publish effects`);
  }
  const stablecoinCurrencyId = await finalizeStablecoinCurrency({
    client,
    keypair: deployerKeypair(deployer),
    ttoCurrencyId,
    stablecoinType,
  });

  const { merchantId, loyaltyPolicyId, stablecoinPolicyId } = await postPublishPTB({
    rpcUrl,
    pasPkg: pasPackageId,
    ozAccessPkg,
    paymentsPkg: payments.packageId!,
    stablecoinPkg: stable.packageId!,
    stablecoinType,
    stablecoinCurrencyId,
    namespaceId,
    templatesId: templatesId!,
    loyaltyCapId,
    stablecoinCapId,
    accessControlId: accessControlId!,
    payoutAddress: deployer,
    deployer,
  });

  // Local gas-station signer for `/api/sponsor`. Only provisioned on ephemeral
  // chains — on testnet/mainnet, Enoki handles sponsorship via the connected
  // wallet, so no server-side sponsor key is needed. Persisted in `.env.local`
  // so subsequent runs reuse the same address; topped up from the localnet
  // faucet on every bootstrap so a freshly-regenesised chain doesn't leave the
  // sponsor broke.
  let sponsorPrivateKey: string | null = null;
  if (ephemeral) {
    const sponsor = resolveSponsorKeypair();
    const sponsorAddress = sponsor.keypair.toSuiAddress();
    console.log(`\n→ funding sponsor address ${sponsorAddress}`);
    await fundFromLocalFaucet(sponsorAddress);
    sponsorPrivateKey = sponsor.privateKey;
  }

  // Public deployment IDs — always written; no risk if exposed (they're
  // already on chain, and the FE imports them client-side via NEXT_PUBLIC_*).
  patchEnv({
    NEXT_PUBLIC_PACKAGE_ID: payments.packageId!,
    NEXT_PUBLIC_MERCHANT_ID: merchantId,
    NEXT_PUBLIC_ACCESS_CONTROL_ID: accessControlId!,
    NEXT_PUBLIC_LOYALTY_POLICY_ID: loyaltyPolicyId,
    NEXT_PUBLIC_STABLECOIN_PACKAGE_ID: stable.packageId!,
    NEXT_PUBLIC_STABLECOIN_POLICY_ID: stablecoinPolicyId,
    NEXT_PUBLIC_STABLECOIN_CURRENCY_ID: stablecoinCurrencyId,
    NEXT_PUBLIC_STABLECOIN_TYPE: stablecoinType,
    NEXT_PUBLIC_NAMESPACE_ID: namespaceId,
    NEXT_PUBLIC_PAS_PACKAGE_ID: pasPackageId,
    NEXT_PUBLIC_OZ_ACCESS_PACKAGE_ID: ozAccessPkg,
    NEXT_PUBLIC_TEMPLATES_ID: templatesId!,
  });

  // Server-side signing keys — only persist on ephemeral (localnet) chains. On
  // testnet/mainnet, auto-exporting these would turn the deployed app's
  // `/api/topup` route into an unauthenticated mint endpoint (deployer holds
  // `TreasuryCap<STABLECOIN_MOCK>`). Operators who genuinely want the dev
  // faucet on a shared chain must populate these manually with full awareness.
  if (ephemeral) {
    patchEnv({
      // Used by `/api/topup` to sign the stablecoin faucet mint.
      DEPLOYER_PRIVATE_KEY: deployerPrivateKey(deployer),
      // Used by `/api/sponsor` to sign the gas leg of localnet sponsored txs.
      // testnet/mainnet sponsor via Enoki, not this key.
      SPONSOR_PRIVATE_KEY: sponsorPrivateKey!,
    });
  } else {
    console.log(
      `\n⚠ ${envAlias}: skipping DEPLOYER_PRIVATE_KEY / SPONSOR_PRIVATE_KEY ` +
        `auto-export. /api/topup and /api/sponsor are gated to localnet at the ` +
        `route layer regardless; populate these manually only if you understand ` +
        `the implications.`,
    );
  }

  // Mirror the per-network file to `.env.local` so the Next.js dev server
  // picks it up. `.env.<network>` remains the source of truth for this
  // network; `pnpm use <network>` swaps which one gets mirrored.
  const perNetworkContents = readFileSync(TARGET_ENV, "utf8");
  writeFileSync(LOCAL_ENV, perNetworkContents, "utf8");

  console.log(`\n✓ Bootstrap complete.`);
  console.log(`  wrote:   ${TARGET_ENV}`);
  console.log(`  mirror:  ${LOCAL_ENV}\n`);
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
