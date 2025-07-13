# GuardChain: Child Welfare & Charity Wallet

## Project Overview

GuardChain is a decentralized solution built on the Stacks blockchain, designed to create secure, age-locked STX wallets for children or for specific charitable purposes. It allows funds to be locked until a predefined block height (representing an age milestone) or released earlier with the explicit approval of a designated guardian. This ensures long-term financial security and controlled access to funds.

## Key Functional Features

*   **Age-Locked Smart Wallets:** Funds are securely held in a smart contract until a specified future block height is reached. This serves as a deterministic, on-chain equivalent of an "age lock."
*   **Guardian Approval for Early Unlock:** A designated guardian can approve the early release of funds before the unlock block height, providing flexibility for unforeseen circumstances.
*   **Secure Fund Management:** Funds are transferred directly into the contract upon wallet creation and can only be withdrawn by the child (or guardian if early approved) once unlock conditions are met.
*   **Transparency:** All wallet details, locked amounts, and unlock conditions are publicly verifiable on the blockchain.
*   **Charity Wallet Potential:** While primarily designed for child welfare, the underlying mechanism can be adapted for charity funds that need to be held for a period or released under specific conditions.

## Smart Contract Details (`guard-chain.clar`)

The core logic of GuardChain resides in the `guard-chain.clar` smart contract.

### Data Structures

*   **Wallet Tuple (defined inline in map)**: Represents an individual locked wallet, storing:
    *   \`child\`: The Stacks principal (address) of the child beneficiary.
    *   \`guardian\`: The Stacks principal of the designated guardian.
    *   \`locked-amount\`: The amount of STX held in the wallet.
    *   \`unlock-block-height\`: The specific block height at which the funds automatically become available for withdrawal.
    *   \`is-guardian-approved-early-unlock\`: A boolean flag indicating if the guardian has approved an early release.
    *   \`is-unlocked\`: A boolean flag indicating if the funds have already been withdrawn.

### State Variables

*   **\`next-wallet-id\`**: A \`uint\` variable that keeps track of the next available unique identifier for new wallets.
*   **\`wallets\`**: A \`define-map\` that stores the \`WalletTuple\` instances, indexed by their unique \`wallet-id\`.

### Public Functions (Callable by Users)

*   **\`create-locked-wallet (child principal, guardian principal, unlock-block-height uint, amount uint)\`**:
    *   Initiated by a donor (often a parent or family member).
    *   Deposits the specified \`amount\` of STX from the donor into the contract.
    *   Creates a new age-locked wallet entry with the designated child, guardian, and unlock block height.
    *   Requires the \`unlock-block-height\` to be in the future.
*   **\`guardian-approve-early-unlock (wallet-id uint)\`**:
    *   Callable only by the designated \`guardian\` of the wallet.
    *   Sets the \`is-guardian-approved-early-unlock\` flag to \`true\`, allowing the child (or guardian) to withdraw funds before the \`unlock-block-height\`.
*   **\`withdraw-funds (wallet-id uint)\`**:
    *   Callable by either the \`child\` or the \`guardian\` (if early unlock is approved).
    *   Checks if the current \`block-height\` has reached or surpassed the \`unlock-block-height\`, OR if \`is-guardian-approved-early-unlock\` is \`true\`.
    *   Transfers the \`locked-amount\` from the contract to the \`child\`'s address.
    *   Marks the wallet as \`is-unlocked\` to prevent multiple withdrawals.

### Read-Only Functions (View Functions)

*   **\`get-wallet-details (wallet-id uint)\`**: Retrieves the full details of a specific wallet.
*   **\`is-wallet-unlockable (wallet-id uint)\`**: Returns \`true\` if the funds in the wallet are currently available for withdrawal (either by block height or guardian approval), \`false\` otherwise.
*   **\`get-next-wallet-id ()\`**: Returns the ID that will be assigned to the next new wallet.
*   **\`get-contract-balance ()\`**: Returns the current STX balance held by the contract.

## Usage Flow (Conceptual)

1.  **Donor creates wallet:** A parent or donor calls \`create-locked-wallet\`, specifying the child's address, a guardian's address, a future block height for automatic unlock, and the amount of STX to deposit. The STX is locked in the contract.
2.  **Time passes / Guardian approval:**
    *   The blockchain continues to produce blocks. Once the current \`block-height\` reaches or exceeds the \`unlock-block-height\`, the funds become automatically available.
    *   Alternatively, the designated \`guardian\` can call \`guardian-approve-early-unlock\` at any time to make the funds immediately available.
3.  **Child (or Guardian) withdraws funds:** Once the unlock conditions are met, either the \`child\` or the \`guardian\` can call \`withdraw-funds\` to transfer the STX from the contract to the child's wallet.

## Development & Testing (with Clarinet)

This contract is designed to be developed and tested using [Clarinet](https://github.com/hirosystems/clarinet), the Clarity testing harness. You can simulate transactions and verify contract behavior in a local development environment.

To get started with Clarinet:
\`\`\`bash
npm install -g @blockstack/clarinet-cli
clarinet new my-guard-chain-project
cd my-guard-chain-project
# Place guard-chain.clar in contracts/
# Write tests in tests/
clarinet test
\`\`\`

## License

[Consider adding a license, e.g., MIT, Apache 2.0]
