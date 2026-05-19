# ⚠️ Project is in progress and might have constant breaking changes!

# Permissioned Asset Standard

## Repository Structure

```
packages/
  pas/          # Core PAS Move package (accounts, policies, requests)
  ptb/          # PTB helper Move package
  examples/     # Example Move packages (e.g. KYC-gated coin)
scripts/
  example-app/  # TypeScript example app using @mysten/pas
```

## Contents

- **SDK**: [`@mysten/pas`](https://www.npmjs.com/package/@mysten/pas) on npm ([source](https://github.com/MystenLabs/ts-sdks))
- **Move Packages**: Smart contracts live in [`packages/`](./packages/)
- **Example App**: SDK usage examples in [`scripts/example-app/`](./scripts/example-app/)

For a detailed design overview, see [`ARCHITECTURE.md`](./ARCHITECTURE.md).

## SDK

The TypeScript SDK is published as [`@mysten/pas`](https://www.npmjs.com/package/@mysten/pas) and lives in the [ts-sdks](https://github.com/MystenLabs/ts-sdks) repository.

```bash
npm install @mysten/pas
```

It plugs into the Sui client via the `$extend` pattern:

```typescript
import { SuiGrpcClient } from '@mysten/sui/grpc';
import { Transaction } from '@mysten/sui/transactions';
import { pas } from '@mysten/pas';

const client = new SuiGrpcClient({ network: 'testnet' }).$extend(pas());

// Send a permissioned balance
const tx = new Transaction();
tx.add(client.pas.call.sendBalance({
  from: sender, // the sender's address
  to: "0x2", // the recipient's address (NOT the account)
  amount: 1_000_000,
  assetType: "0xa::permissioned::ASSET",
}));
```

See [`scripts/example-app/`](./scripts/example-app/) for a full working example.
