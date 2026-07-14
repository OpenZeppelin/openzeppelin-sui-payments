# dApp overview

Landing page, login, and how the app decides where to send you next. For
the page-by-page tours of the two dashboards, see
[OVERVIEW_CUSTOMER.md](OVERVIEW_CUSTOMER.md) and
[OVERVIEW_MERCHANT.md](OVERVIEW_MERCHANT.md). For the design decisions
behind the on-chain contracts, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Landing page

The single entry point at `/`. When no wallet is connected, the page shows
two manual-preview cards - **Continue as merchant** and **Continue as
customer** - so anyone can browse either dashboard without connecting.
The **Log in** button in the header is what turns the preview into a real
session: once a wallet connects, the landing page auto-routes to the right
dashboard and the manual cards disappear.

![Landing page with the Log in popover open - page title "OpenZeppelin Sui Payments", tagline about closed-loop stablecoin payments, two manual-entry cards (Continue as merchant, Continue as customer) faded behind the popover, popover listing Continue with Google, Continue with Facebook, Continue with Twitch, followed by the Slush wallet extension entry](images/main_page_with_login_popup.png)

## Login options

Two ways to log in, both surfaced through the same picker:

### Google (Enoki-registered walletless zkLogin)

**Continue with Google** - and equivalently **Facebook** / **Twitch** - go
through Enoki's zkLogin flow. No browser extension, no seed phrase; a
Google OAuth popup returns a `id_token` that Enoki turns into a proof, and
dapp-kit registers the result as a first-class wallet. The address is a
regular Sui address you can also use with any other Sui dApp.

On testnet + mainnet the Google path is the recommended default because it
composes with Enoki-sponsored transactions: `useSponsoredMutation` routes
Enoki wallets through `/api/enoki-sponsor` + `/api/enoki-execute`, so users
never need SUI in their account to pay for gas. See
[ARCHITECTURE.md § 6](ARCHITECTURE.md#6-sponsored-transactions-with-a-three-way-branch).

On localnet the Google option is **not usable** - Enoki's prover runs on
Mysten infra with a max-epoch delta of 30, and localnet's epoch is
disconnected from Mysten's testnet-derived `maxEpoch`. The picker still
shows the option (it's a runtime property of the registered wallet), but
signing fails. Use Slush on localnet.

### Slush (and other extension wallets)

Below the Enoki entries the picker lists every installed extension wallet
- Slush, Suiet, Sui Wallet, etc. Extension wallets always work on every
network (localnet included) and cover the "user brings their own keys"
case. On testnet, extension wallets sign the tx themselves and pay gas
from their own balance (the sponsorship branch that doesn't route through
Enoki - see the same ARCHITECTURE section).

Behind the scenes the picker is [`ConnectButton`](../app/src/components/connect-button.tsx),
a custom replacement for dapp-kit's built-in modal. It re-labels every
option as "Continue with X" for friendliness and sorts Enoki entries
first so the walletless path is what non-Sui users see first.

## Routing after login

The landing page runs one dev-inspect PTB against
`access_control::has_role<MERCHANT, {MerchantRole, CatalogManagerRole,
CashierRole}>` for the connected address, three role checks bundled into a
single call. If **any** returns `true`, the router replaces the current
history entry with `/merchant/catalogue`; otherwise it replaces with
`/customer`. Because `router.replace` (not `push`) is used, hitting
Back doesn't bounce the user through the landing page again.

The manual preview cards from the disconnected state are still reachable
by clicking a header link back to `/` while disconnected - useful when
demoing the merchant flow with a customer wallet or vice-versa. Once a
wallet is connected the auto-route always fires; disconnect first if you
want to see the other side without granting a new role.

**Practical consequences:**

- A fresh customer wallet (no roles) lands on `/customer`. They can top up,
  scan to pay, browse rewards, view history - everything under
  [OVERVIEW_CUSTOMER.md](OVERVIEW_CUSTOMER.md).
- The deployer wallet (holds all three staff roles after
  `pnpm bootstrap`) lands on `/merchant/catalogue`. Everything under
  [OVERVIEW_MERCHANT.md](OVERVIEW_MERCHANT.md) is theirs.
- To grant merchant access to another wallet, use
  `access_control::grant_role` against the shared
  `AccessControl<MERCHANT>` object with the appropriate role type
  (`MerchantRole` / `CatalogManagerRole` / `CashierRole`). Any single one
  is enough to auto-route into `/merchant/catalogue`.

## Where to go next

- [OVERVIEW_CUSTOMER.md](OVERVIEW_CUSTOMER.md) - customer-side pages:
  dashboard, top up, scan to pay, rewards, history.
- [OVERVIEW_MERCHANT.md](OVERVIEW_MERCHANT.md) - merchant-side pages:
  catalogue + invoicing, redeem, transactions feed, settings, balance.
- [ARCHITECTURE.md](ARCHITECTURE.md) - design rationale, module layout,
  PTB flow diagram, known limitations.
- [Top-level README](../README.md) - install, `pnpm bootstrap` / `pnpm seed`
  flow, env vars.
