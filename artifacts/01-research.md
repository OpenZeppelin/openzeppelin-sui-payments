---
stage: research
project: openzeppelin-sui-payments
mode: greenfield
extends: null
status: draft
timestamp: 2026-05-19
author: Alisander Qoshqosh
previous_stage: null
tags: [pas, payments, loyalty, soulbound, template, openzeppelin, qr-payments]
---

# OpenZeppelin Sui Payments Template — Research Report

## Summary

A focused survey of the Sui ecosystem and adjacent chains shows this template fills a real gap: there is **no public developer reference** that demonstrates an end-to-end closed-loop stablecoin checkout + soulbound fungible loyalty + code-bound redemption built on the modern Sui standards (PAS, capability access control, sponsored transactions, zkLogin). Adjacent efforts exist (Mysten's PAS reference, S3.MONEY / Walletify, Sui's deprecated `sui::token` loyalty examples, Solana Pay on another chain) but none provide an open OZ-quality template a developer can fork. Verdict: **build**, scoped as a single-tenant reference template with a clear extension path to multi-merchant and to OZ AccessControl once that ships.

## Existing Sui Implementations

### Permissioned Asset Standard (PAS) — `MystenLabs/pas`

- **Status:** Testnet only; README explicitly warns "in progress, may have constant breaking changes."
- **Positioning:** Successor to the deprecated `sui::token` (Closed-Loop Token, CLT). All new closed-loop work should target PAS, not CLT.
- **Shape:** Balances are held in derived per-asset `Account` objects, but transfers target the **wallet address** rather than the Account address. Authorization flows through a **hot-potato request**: any movement (transfer, spend, mint, burn, custom action) creates a `Request<T>` that must pass each rule registered on the asset's policy and be resolved in the same PTB.
- **Available consumer surface:** TypeScript SDK `@mysten/pas` with helpers like `client.pas.call.sendBalance({ from, to, amount, assetType })`.
- **Gaps for our use:**
  - No reference example of a PAS-based **escrow / hold** for fungible balances. Holds are needed for the redemption flow (lock loyalty, release on expiry or burn on verify) and are unspecified prior art — the template will need to design this pattern.
  - No reference example of **fungible soulbound** under PAS. PAS makes "non-transferable" trivial by registering a transfer rule that always rejects, but we should validate the exact rule shape against the reference examples (KYC-gated coin example in `packages/examples/` is the closest analog).
  - No reference example of **atomic mint-as-part-of-payment**. PAS mint is an action like any other; bundling a spend (payment) and a mint (loyalty) in one PTB is mechanically possible but the trust model for the mint authority must be designed (see Recommendation §1).
- **Source:** [MystenLabs/pas](https://github.com/MystenLabs/pas), [PAS Architecture docs](https://docs.sui.io/standards/pas/pas-architecture).

### Stablecoin Studio on Sui (S3.MONEY) and Walletify

- **What it is:** Pravica-built compliant stablecoin issuance platform on Sui, paired with a closed-loop consumer payment app ("Walletify"). Targets stablecoin **issuers** (KYC/AML, proof-of-reserve, role-based admin, treasury management) and provides Walletify as the end-user wallet/payment surface.
- **No public Move source repository found** — S3 is positioned as a hosted product / SaaS, not a developer-fork reference.
- **Overlap with our template:** Walletify is *the* prior art closest in user-experience to "Joe's Coffee." However:
  - Walletify is a **consumer app** for an already-issued S3 stablecoin, not a developer-reusable template.
  - S3 is an **issuer platform**, not a merchant integration recipe.
  - Neither demonstrates the soulbound loyalty + code-bound redemption pattern this template provides.
- **Verdict on overlap:** Different audience — S3 serves issuers and their wallet partners; this template serves developers building merchant-side dApps. Both can coexist; the template can even position itself as something a merchant integrating with an S3-issued stablecoin could fork.
- **Sources:** [S3 announcement](https://decrypt.co/220788/stablecoin-studio-on-sui-s3-to-give-sui-developers-compliant-payment-processing-stablecoin-applications), [Hedera Stablecoin Studio (unrelated; same name)](https://github.com/hashgraph/stablecoin-studio).

### `sui::token` (Closed-Loop Token) — deprecated but instructive

- **Status:** Superseded by PAS per Sui's standards page. New work should not target this.
- **Why it still matters as prior art:**
  - The `reward_user` pattern in the official `sui::token` loyalty tutorial is the canonical Sui idiom for atomic mint-during-payment: the merchant holds (or the module wraps) a `TreasuryCap`, and a single function takes a payment and emits a mint. This is the trust-model template we should mirror with PAS primitives.
  - The CLT `TokenPolicy` rule system is the conceptual ancestor of PAS's policy rules — devs familiar with CLT will read PAS docs through that lens.
- **Source:** [Sui Loyalty Tokens guide](https://docs.sui.io/onchain-finance/examples-patterns/loyalty-tokens), [CLT spending docs](https://docs.sui.io/standards/closed-loop-token/spending).

### Circle's USDC on Sui — `circlefin/stablecoin-sui`

- **What it is:** Circle's production USDC implementation for Sui — a plain `Coin<USDC>` (Sui Coin standard, not PAS).
- **Implication for the template:** Real production stablecoin on Sui today is **not PAS-issued**. The template's PAS-based payment flow is a clean reference for *closed-loop or issuer-controlled* stablecoins; it does **not** drop-in replace USDC. This is a framing point the README must make explicit so adopters don't expect to swap in USDC and get the same flow (see Recommendation §3).
- **Source:** [circlefin/stablecoin-sui](https://github.com/circlefin/stablecoin-sui).

### OpenZeppelin Contracts for Sui — `OpenZeppelin/contracts-sui`

- **What ships today:** Foundational release with a DeFi Math library and an **Ownable**-style access management module (single-owner capability pattern). Not full role-based AccessControl yet.
- **In progress (per repo issues, including the issue the spec references):** Full `AccessControl` with hierarchical roles, expected later this cycle.
- **Implication for the template:** Use the Sui-native capability pattern for v1 (matches what's available, audited, and idiomatic), and document the AccessControl migration path. Do not depend on the in-progress AccessControl module in v1.
- **Sources:** [contracts-sui](https://github.com/OpenZeppelin/contracts-sui), [OZ for Sui announcement](https://www.openzeppelin.com/news/introducing-openzeppelin-contracts-for-sui), [Capability pattern](https://move-book.com/programmability/capability/).

### Sui-native infra (treated as known building blocks, not surveyed)

- **zkLogin** — Sui's first-party social-login → on-chain identity primitive. Used directly or wrapped by Enoki/Shinami.
- **Enoki** (Mysten) and **Shinami** — both provide sponsored-transaction "gas station" services and WaaS / Invisible Wallet flows. Mature, well-documented. The template just needs an integration point; provider choice is a deployment-time decision, not a design-time one.
- **Sources:** [Enoki Sponsored Transactions](https://docs.enoki.mystenlabs.com/ts-sdk/sponsored-transactions), [Shinami Gas Station](https://docs.shinami.com/product-overviews/sui/gas-station), [zkLogin guide](https://docs.sui.io/guides/developer/cryptography/zklogin-integration/zklogin).

## Cross-Ecosystem Implementations

### Solana — Solana Pay (directly applicable)

- **What it is:** A QR-encoded URL spec for payment requests. Two flavors:
  - **Transfer Request** — a fully self-describing URL (recipient, amount, SPL token mint, memo, reference). Customer wallet composes the transfer locally.
  - **Transaction Request** — the URL is an HTTPS endpoint. The wallet GETs metadata, POSTs the customer's pubkey, and the merchant server returns a base64 transaction. The customer wallet signs and submits.
- **Concept worth porting verbatim — `reference` fields:** Solana Pay injects a unique account key into the transaction as a "reference" so the merchant can index the chain and confirm the specific payment **before knowing the eventual transaction signature**. This solves "did order #1234 actually pay?" without polling-by-signature. **The user's spec does not currently describe this** and it is the key missing piece for merchant payment verification.
- **Implication for our template:** For atomic payment + loyalty mint in one PTB, we need the **transaction-request** model (the QR is a URL, the merchant backend composes the PTB). The simpler transfer-request shape doesn't compose the mint side. Sui's analog of `reference`: a per-order identifier carried in the `Payment` event (and, optionally, in a per-order shared `PaymentIntent` object the merchant indexer watches).
- **Source:** [Solana Pay spec](https://docs.solanapay.com/spec).

### Solidity / EVM

- **Starbucks Odyssey (Polygon, Nifty Gateway, Forum3):** Direct cultural precedent for a coffee-shop Web3 loyalty program. Built around **NFT "Journey Stamps"** (collectibles), not fungible points. Ended March 2024 after an 18-month beta. Useful as a *cautionary* reference: the failure modes were product/strategy, not technology — the chain choice and SBT mechanics worked, but the program lacked a real reason for customers to come back. **Lesson for the template:** keep the fungible-points + free-product redemption model — concrete utility — rather than chasing the NFT-stamp pattern.
- **EIP-5192 (Minimal Soulbound NFTs):** The minimal EVM SBT standard. Just adds a `locked(tokenId)` view returning `true`. Validates that on EVM, "soulbound" is a single-bit constraint, not a complex flow. Reinforces our approach: PAS + transfer-always-rejects rule is the equivalent minimal pattern on Sui.
- **Merchant USDC checkout patterns (Coinbase Commerce, Shopify integrations):** Off-chain merchant pays out to on-chain wallet, then the merchant dashboard reconciles. Different model — there's no atomic loyalty mint, no on-chain redemption ledger. Not a useful structural reference for our template, only for the *off-ramp* (deferred / mocked in v1).
- **Sources:** [Starbucks Odyssey wrap-up — Coindesk](https://www.coindesk.com/business/2024/03/19/polygon-labs-paid-4m-to-host-starbucks-doomed-foray-into-crypto), [EIP-5192](https://eips.ethereum.org/EIPS/eip-5192).

### Aptos Move

- **Fungible Asset standard (`0x1::fungible_asset` + `0x1::dispatchable_fungible_asset`):** Aptos's modern token primitive, closest language-and-design relative to PAS. Holders have per-asset `FungibleStore` objects (analogous to PAS `Account`s). The `dispatchable_fungible_asset` extension lets the issuer register a custom hook to gate `deposit` / `withdraw` — direct analog of PAS rules.
- **Soulbound on Aptos:** Implemented by registering a `dispatch::withdraw` hook that always aborts (parallel to "transfer rule that always rejects" on PAS). Same pattern, different runtime.
- **Implication for the template:** PAS is on a deliberate path that mirrors what Aptos shipped to mainnet. The patterns we build on PAS today should be portable conceptually — if PAS undergoes breaking changes pre-mainnet, the Aptos prior art is a good guide to where things are likely to land.
- **Sources:** [Aptos Fungible Asset framework](https://aptos.dev/standards/fungible-asset/).

## Ecosystem Needs

- **Sui developer template gap:** Sui's documentation gives examples for *individual* primitives (a loyalty token, a closed-loop coin, a soulbound NFT) but no end-to-end **payment-plus-loyalty merchant dApp** that wires them together. Developers building a Joe's-Coffee-style app today must compose these themselves — exactly the gap an OZ template fills.
- **Merchant payment verification:** No published Sui pattern for "merchant POS scans customer QR → merchant verifies order #1234 paid before fulfilling." Solana Pay's `reference` pattern is the missing piece; we should port the concept.
- **Sponsored UX for non-crypto users:** Demand is clearly there (every major Sui infra provider — Enoki, Shinami, Ignitia — built a gas station). The template demonstrates how to *use* one, not which one to use.
- **Migration path from `sui::token` to PAS:** Many existing tutorials still target CLT. A current, idiomatic PAS template is itself ecosystem-useful as a teaching artifact.

## Gap Analysis

| Gap | Filled by this template? |
|---|---|
| End-to-end PAS-based merchant payment + loyalty reference | **Yes — primary contribution** |
| Sui equivalent of Solana Pay's `reference`-based payment verification | **Yes — port the pattern via event + per-order intent** |
| PAS-based escrow / hold pattern for fungible balances | **Yes — design originates here** |
| Capability-based merchant role with a documented AccessControl migration path | **Yes** |
| Demonstrates sponsored-tx + zkLogin/WaaS for a non-crypto user | **Yes (light)** |
| Multi-merchant marketplace | No — scope-excluded. The template is single-tenant. |
| Real fiat off-ramp | No — mocked in v1 per dev direction. |
| Confidential / privacy-preserving transfers | No — deferred. |

## Recommendation

- **Verdict:** **Build.** No existing Sui implementation fills the developer-template gap for end-to-end PAS-based payments + loyalty + redemption. S3/Walletify serve a different audience (issuers and their consumer-app partners). The OZ template targets developers forking a reference dApp.

- **Recommended approach:** Single Move package with five tightly-scoped modules — `payment`, `loyalty`, `redemption`, `catalog`, and an `access` shim around the capability pattern (positioned for clean migration to OZ AccessControl when ready). Bind everything together with a single shared `MerchantConfig` object that owns the wrapped capabilities (loyalty `MintCap`, redemption verify gate) and the policy parameters. Mirror the Sui `reward_user` pattern: the payment entry function takes the customer's PAS spend request, opens a mint request in the same PTB using the shared `MintCap`, and bundles them in one atomic action. For the QR / payment-intent flow, port Solana Pay's `reference` concept: each "sale" creates (or references) a per-order `PaymentIntent` object the merchant indexer watches; the `Payment` event carries the intent ID. For redemption, design a `Hold` hot-potato pattern: customer's redeem-request locks a balance into a `Hold` object that stores `hash(code)` and a `Clock`-based expiry, the merchant submits the preimage in a $0 verification tx to burn, and anyone may call `release` after expiry.

- **Key design considerations:**
  1. **MintCap trust model.** The atomic-mint-during-payment flow requires the payment function to access the loyalty `MintCap`. Wrap it in the shared `MerchantConfig` with a rate-bounded rule (e.g., max mint per spend, max mint per second) rather than having the merchant co-sign every payment. The co-sign alternative kills the sponsored-tx UX. Document the trust boundary.
  2. **Redemption hold mechanics.** PAS does not provide an escrow primitive out of the box. The `Hold` object must (a) lock the soulbound balance, (b) bind to the off-chain code via `hash(code)` preimage commit-reveal (not the hold's ID — that would leak via the QR), (c) expire via `Clock`, and (d) expose a **permissionless** release after expiry so users can't be griefed by an inactive merchant. This is genuinely new design work — the largest design-stage open question.
  3. **Sui-native `reference` / payment-intent pattern.** Solana Pay's `reference` solves "did order N pay?" without polling the chain by signature. Sui equivalent: a `PaymentIntent` shared object created at QR-render time (or a strongly-typed event keyed on order ID). Merchant indexer watches for the intent transitioning to "paid." Without this, the POS-integration story in the spec doesn't actually work — the merchant has no idempotent way to confirm receipt.
  4. **PAS testnet status.** PAS is testnet-only with explicit breaking-changes warnings. The template should pin to a specific PAS commit SHA, document the pin, and structure the access layer so a future migration is local (a single `access` module, not capability checks scattered across every entry).
  5. **Real-stablecoin scope clarity.** Frame the template in the README as *"closed-loop / issuer-controlled stablecoin checkout"*, not generic stablecoin checkout. Drop-in USDC is **not** supported because USDC on Sui is `Coin<USDC>`, not PAS-issued. Surface this in the first paragraph to prevent the obvious adopter confusion.

- **Risks:**
  - **PAS breaking changes** before mainnet. Mitigate via commit pinning, isolating PAS calls behind thin wrappers in `payment` and `loyalty`, and documenting the pin.
  - **PAS rule composition edge cases.** Stacking the payment policy's transfer rule with the loyalty asset's "always reject transfers" rule plus the mint rate rule has limited prior art. Allocate test budget; the BTT stage (post-core) will help.
  - **Hold-pattern security.** The redemption flow is the most novel mechanic; a careless implementation can leak the preimage, allow double-burn, or strand balances. Treat this as the primary target for the basic-review post-core stage.
  - **OZ AccessControl timing.** If OZ ships AccessControl during v1 development, the dev may want to step back to design and adopt it. The `access` shim limits the blast radius of that change but doesn't eliminate it.

## Out of Scope

- **Multi-merchant / marketplace support** — per dev spec, single-tenant template only.
- **Real fiat on/off-ramp** — mocked in v1; real integration is a separate workstream.
- **Real USDC on Sui** — USDC is Sui-Coin, not PAS; the template uses a mock PAS stablecoin and frames the production answer as "any issuer-controlled / PAS stablecoin." Drop-in USDC is excluded.
- **Receipt NFTs with restricted visibility** — deferred per spec; the design should leave hooks (Payment event extensibility) so v2 can add this without breaking changes, but no design work in v1.
- **Loyalty leaderboard, confidential transfers, multiple custom attributes per catalog item** — all deferred per spec.
- **SDK packaging of the Move modules as a standalone importable library** — deferred per spec; v1 ships as a forkable template, not an npm-published Move package.
- **In-depth Aptos / Solidity Move-side comparison beyond what's above** — Aptos `dispatchable_fungible_asset` is referenced as a parallel design for portability reasoning, not as something to mirror line-by-line.
- **WaaS provider selection (Enoki vs Shinami vs custom zkLogin)** — both providers are documented; integration boundary is small and provider choice is a deployment-time decision, not a Move-side design decision.

## Dev Notes

This artifact was produced in **quick-research** mode after the dev moved to `/sui-design` before completing the standard research stage. The light grounding pass from scope alignment and three focused passes (Stablecoin Studio overlap, PAS escrow / soulbound prior art, MintCap trust-model prior art) are merged here. Sections that would normally include deeper cross-ecosystem surveys (full Aptos `dispatchable_fungible_asset` walkthrough, broader EVM merchant-checkout review) are intentionally narrower — flagged here so Invariants / Code stages know what was *not* researched in depth.

## Open Questions

1. **Mock stablecoin** — issue our own PAS-based mock for the template (cleanest, fully closed-loop reference), or assume an externally-deployed PAS stablecoin and demonstrate integration? Affects the `payment` module's coupling to the mock and the deployment script. *Lean: issue our own — it makes the template self-contained, and the "swap in your own" story is documented.*
2. **PaymentIntent — shared object or events-only?** A `PaymentIntent` shared object gives the merchant a clean on-chain handle but adds contention and gas. Events-only with an order-ID reference field is cheaper but pushes more state to the merchant indexer. *Design stage decides.*
3. **Hold preimage scheme** — plain `hash(code)` is enough if the code has sufficient entropy (≥128 bits). Should the design require a salt to avoid rainbow tables for short codes, or is "use a long random code, period" sufficient? *Design stage decides.*
4. **Single MerchantCap or per-role caps?** v1 spec implies one cap with the merchant doing everything (catalog CRUD, verify redemption, withdraw balance). Document this consciously and call out that the AccessControl migration is where role decomposition happens.
5. **Faucet for mock stablecoin top-up** — gated by anything (zkLogin presence, rate limit) or fully permissionless? *Design stage decides — primarily affects DX of the template.*
