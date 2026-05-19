# Permissioned Assets Standard — Architecture

The Permissioned Assets Standard is a framework for issuing and managing permissioned balances on Sui. It enables tokenization of real-world fungible assets with built-in compliance mechanisms, transfer restrictions, and regulatory controls.

## TLDR

1. Each address has a single account (derived address, with easy discoverability). Objects can own accounts as well. This enables with account abstractions / defi protocols implementations
2. Account uses address (object) balances, so RPCs work out of the box (wallet just treats the account address like a normal one). Wallets/explorers needs to query for the derived account address to get balances.
3. Balances can only move from account to account (either by safe account-to-account deposits, or deriving the recipient with `unsafe_` calls)
4. When a transfer is initiated, a `SendFunds` is issued, which can be resolved, on the PTB layer, calling the `Command` that is specified by the issuer. The issuer can "approve" it in their own package by presenting a witness. Any custom logic (KYC, checks) can be implemented there.
5. Clawback is available (accounts are shared and a clawback can be initiated using the issuer's witness).

(To be added: Issuers can attach "metadata" to user's Accounts (such as `KYC` stamps or AML stamps they issue), which they can then check on their transfer functions to restrict movement. Since accounts are shared, issuers can revoke these stamps at any moment).

## Key Features

- **Permissioned Transfers**: All transfers must go through accounts and be approved by custom transfer rules
- **Account-Based Architecture**: Tokens can only be held in accounts, with automatic balance tracking
- **Flexible Policies System**: Each token type has associated rules that govern transfers with jurisdiction-specific compliance
- **Optional Clawback**: Regulatory compliance feature that allows token recovery when legally required

## How It Works

1. **Setup**: Registry is created as a shared object, token issuers register their tokens with rules
2. **Account Creation**: Accounts are derived for each address that needs to hold tokens
3. **Transfers**: Initiated from source account, creating a transfer request that must be resolved by the policy
4. **Resolution**: Token-specific smart contracts validate and approve transfers based on compliance rules

## Wallet & SDK Integration

### Simple Discovery
The standard uses derived objects for predictable addresses:
- **Single account per user** which holds the balances of the user
- **No indexing required** - account and policy addresses are deterministically computable
- **One query** to see all user balances via dynamic fields on their account

### Easy Resolution

Each policy contains `Command` instructions that tell SDKs exactly how to resolve transfers - no need to understand complex on-chain logic. SDKs simply read the command and construct the appropriate transaction.

## Security Features

- **Ownership Proofs**: Ensure only legitimate owners can initiate transfers
- **Transfer Restrictions**: All transfers generate hot potato requests that must be resolved by the issuer
- **Immutable Clawback**: Optional feature that can only be set at registration

## Benefits

- **Regulatory Compliance**: Built-in KYC/AML (or any arbitrary logic) support for issuers
- **Flexibility**: Custom rules per token type with extensible off-chain resolution mechanisms
