# KipuBank: Multi-Asset Decentralized Vault

This repository presents the advanced **KipuBank** smart contract, a secure, educational implementation of a decentralized banking vault on the Ethereum Virtual Machine (EVM). It enables users to deposit native ETH and various ERC-20 tokens while maintaining solvency through a robust, USD-based accounting system powered by Chainlink.

---

## High-Level Upgrades & Rationale

The contract has evolved significantly from a single-asset (ETH) vault with static limits to a multi-asset system focused on stability and modern DeFi practices.

1.  **USD-Based Solvency:** Limits are now enforced based on the **USD value** of the deposits, rather than volatile native token amounts (Wei). This ensures the bank's global cap (`i_bankCapInUSD`) remains stable and reliable, independent of market fluctuations.
2.  **Multi-Asset Support:** Users can deposit both **native ETH** and any **ERC-20 token**, using a unified internal accounting system based on **6 decimals** (simulating USDC standard).
3.  **Chainlink Oracle Integration:** The contract utilizes the **Chainlink AggregatorV3Interface** for real-time ETH/USD price data, which is essential for accurate USD conversion and preventing deposits if the oracle data is stale or invalid.
4.  **Robust Access Control:** **OpenZeppelin's AccessControl** is implemented, establishing a dedicated **`MANAGER_ROLE`** for key administrative functions, such as updating the price oracle address or executing treasury withdrawals.

---

## ⚙️ Deployment and Initialization Instructions

The `KipuBank` contract is designed for deployment on an EVM-compatible testnet like **Sepolia**.

### Deployment Parameters

The contract requires three constructor arguments to configure its security and administrative features:

| Parameter | Type | Example Value | Purpose |
| :--- | :--- | :--- | :--- |
| `_bankCapInUSD` | `uint256` | `1000000000` | The **maximum total value (in 6 decimals USD)** the bank can hold globally. |
| `_priceFeed` | `address` | `0x694AA1769357215DE4FAC081bf1f309aDC325306` | The **Chainlink ETH/USD Price Feed** address (Sepolia). |
| `_initialAdmin` | `address` | `0x...` | The wallet address receiving the `DEFAULT_ADMIN_ROLE` and `MANAGER_ROLE`. |

### How to Interact with KipuBank

| Function | Type | Purpose | Key Check |
| :--- | :--- | :--- | :--- |
| **`depositETH()`** | `external payable` | Deposit native ETH. | Reverts if the deposit value exceeds the global cap (`i_bankCapInUSD`). |
| **`depositERC20(address _token, uint256 _amount)`** | `external` | Deposit any ERC-20 token (requires prior `approve`). | Converts amount to USD value and checks against the global cap. |
| **`withdraw(address _token, uint256 _amount)`** | `external` | Withdraw deposited assets (ETH or ERC-20). | Checks the user's balance in **internal 6-decimal units** before transferring. |

### Administration (MANAGER_ROLE)

* **`managerWithdrawTreasury(address _token)`:** Allows a manager to sweep the treasury balance of a specified token.
* **`setPriceFeed(address _newFeedAddress)`:** Allows a manager to update the Chainlink oracle address.

---

## 📐 Design Decisions & Trade-offs

The primary design trade-off is the **reliance on external price data** for core functionality. While using Chainlink ensures accuracy and stability (USD-based limits), it introduces a dependency on an oracle. This risk is mitigated by enforcing a **staleness check** (`ORACLE_HEARTBEAT`) that prevents any deposit if the price data is too old.

Furthermore, the use of **AccessControl** grants essential management capabilities, introducing a degree of centralization necessary for the initial governance of the bank's external dependencies.
Purpose: Allows the user to retrieve deposited assets.

Parameters: _token (address(0) for ETH) and the _amount in the token's native decimals.

Fails if: The user's internal 6-decimal balance is insufficient (throws KipuBank_InsufficientFunds).

---

## Deployed Contract Address

| Network | Address |
| :--- | :--- |
| **Testnet (Sepolia)** | `0x516Af71D756c2324988ACe1dE56A6E1445E1f9b4` |

**Block Explorer:** [https://sepolia.etherscan.io/address/0x516Af71D756c2324988ACe1dE56A6E1445E1f9b4#code](https://sepolia.etherscan.io/address/0x516Af71D756c2324988ACe1dE56A6E1445E1f9b4#code)
