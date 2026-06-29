/**
 * Single source of truth for the deployed package IDs. Values come from
 * `scripts/bootstrap.ts`, which writes them into `.env.local` after running
 * `sui client publish` for both `contracts/payments/` and
 * `contracts/stablecoin-mock/`.
 *
 * Throwing on missing IDs at module load means a misconfigured environment
 * fails fast with a useful message instead of producing nondescript PTB
 * errors at the first chain call.
 */

function required(name: string, value: string | undefined): string {
  if (!value || value.length === 0) {
    throw new Error(
      `Missing required environment variable \`${name}\`. ` +
        `Run \`pnpm bootstrap\` (or set it manually in app/.env.local).`,
    );
  }
  return value;
}

function optional(value: string | undefined): string | null {
  return value && value.length > 0 ? value : null;
}

/** Lazy accessor — only required when a page actually touches the chain. */
export const deployment = {
  get packageId(): string {
    return required("NEXT_PUBLIC_PACKAGE_ID", process.env.NEXT_PUBLIC_PACKAGE_ID);
  },
  get merchantId(): string {
    return required("NEXT_PUBLIC_MERCHANT_ID", process.env.NEXT_PUBLIC_MERCHANT_ID);
  },
  get accessControlId(): string {
    return required(
      "NEXT_PUBLIC_ACCESS_CONTROL_ID",
      process.env.NEXT_PUBLIC_ACCESS_CONTROL_ID,
    );
  },
  get loyaltyPolicyId(): string {
    return required(
      "NEXT_PUBLIC_LOYALTY_POLICY_ID",
      process.env.NEXT_PUBLIC_LOYALTY_POLICY_ID,
    );
  },
  get stablecoinPackageId(): string {
    return required(
      "NEXT_PUBLIC_STABLECOIN_PACKAGE_ID",
      process.env.NEXT_PUBLIC_STABLECOIN_PACKAGE_ID,
    );
  },
  get stablecoinPolicyId(): string {
    return required(
      "NEXT_PUBLIC_STABLECOIN_POLICY_ID",
      process.env.NEXT_PUBLIC_STABLECOIN_POLICY_ID,
    );
  },
  /**
   * Shared `Currency<STABLECOIN_MOCK>` object id, created by the stablecoin's
   * `init` via `coin_registry::new_currency_with_otw`. Read by
   * `config::new<C>(&Currency<C>, …)` whenever the merchant edits config.
   */
  get stablecoinCurrencyId(): string {
    return required(
      "NEXT_PUBLIC_STABLECOIN_CURRENCY_ID",
      process.env.NEXT_PUBLIC_STABLECOIN_CURRENCY_ID,
    );
  },
  /** Fully-qualified type of the accepted stablecoin, e.g. `0xab..::stablecoin_mock::STABLECOIN_MOCK`. */
  get stablecoinType(): string {
    return required(
      "NEXT_PUBLIC_STABLECOIN_TYPE",
      process.env.NEXT_PUBLIC_STABLECOIN_TYPE,
    );
  },
  get loyaltyType(): string {
    // LOYALTY lives under our payments package: `${packageId}::loyalty::LOYALTY`.
    return `${this.packageId}::loyalty::LOYALTY`;
  },
  /** Vendored PAS package address (per-publish; bootstrap script writes it). */
  get pasPackageId(): string {
    return required("NEXT_PUBLIC_PAS_PACKAGE_ID", process.env.NEXT_PUBLIC_PAS_PACKAGE_ID);
  },
  /** Shared `Namespace` object created at PAS init time. Needed for every PAS call. */
  get namespaceId(): string {
    return required("NEXT_PUBLIC_NAMESPACE_ID", process.env.NEXT_PUBLIC_NAMESPACE_ID);
  },
  /** openzeppelin_access package — hosts `access_control::{new_auth,grant_role}`. */
  get ozAccessPackageId(): string {
    return required(
      "NEXT_PUBLIC_OZ_ACCESS_PACKAGE_ID",
      process.env.NEXT_PUBLIC_OZ_ACCESS_PACKAGE_ID,
    );
  },
};

/** Enoki public API key. Optional — when missing, sponsored tx still works server-side. */
export const enokiPublicKey = optional(process.env.NEXT_PUBLIC_ENOKI_API_KEY);
