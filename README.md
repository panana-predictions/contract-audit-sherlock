# 🧠 Panana Prediction Markets – Aptos Move Smart Contracts

This repository contains smart contracts for two core market types within the Panana ecosystem:

1. **Share Markets** – A Uniswap V2-style prediction AMM inspired by Polkamarkets
2. **Crypto Price Predictions** – A fast-paced, fully on-chain prediction mechanism powered by Pyth oracles

---

## Part 1: 📈 Share Markets (Binary Prediction AMM)

The Share Markets module implements a **binary outcome prediction market** using a constant product AMM model. The system is inspired by [Polkamarkets V2](https://help.polkamarkets.com/polkamarkets-v2) and enhanced for on-chain composability and capital efficiency.

### 🔑 Key Concepts

- **Binary Markets:** Each market supports two outcomes: **Yes** or **No**.
- **Fungible Shares:** Outcome shares are fungible tokens (e.g., `YesToken`, `NoToken`) that users receive in exchange for depositing a base asset (e.g., USDC).
- **Permissionless Market Creation:** Anyone can create markets. Admins can additionally provide synthetic liquidity.
- **AMM Pricing:** Share prices dynamically adjust via a Uniswap V2-style constant product formula.
- **Liquidity Threshold:** Markets become active only after reaching a minimum liquidity level.

### 💧 Liquidity Provision

- **Normal Liquidity**
  - Users deposit base assets into the market.
  - They receive **LP tokens** and earn trading fees.

- **Synthetic Liquidity (Admin-only)**
  - No upfront deposit required.
  - Admin receives **LPS tokens** and must deposit required funds at resolution to pay winners.
  - Enables capital-efficient liquidity provisioning.

### 🧮 Fees

Three fee types apply:
1. Market Creator Fee
2. Marketplace Operator Fee
3. Liquidity Provider Fee

- Fees can be configured independently for **Buy** and **Sell**.
- Fees from inactive sellers are automatically collected at resolution.

### ⚖️ Resolution & Dispute Flow

- A **resolver** submits the outcome.
- A **challenge period** allows users to dispute the resolution by staking a challenge fee.
- A **Resolution Oracle** settles challenged markets.
  - If successful, challengers are refunded.
  - If not, the oracle receives the fee.

### 🔐 Security & Design

- Slippage protection via `slippage_min_out`
- Token minting tightly scoped
- Fully modular architecture

### 🚫 Limitations

- Only binary markets supported
- Manual expiration/resolution required
- Depends on off-chain inputs for resolution

---

## Part 2: ⚡ Crypto Price Predictions (Short-Term On-Chain Price Markets)

The Crypto Price Predictions module enables users to predict short-term price movements of crypto assets in a decentralized, automated manner.

### 🔑 How It Works

- Users predict whether the **price will go up or down** within a predefined timeframe.
- Users commit funds into a prediction pool by selecting **Up** or **Down**.
- The **total pool** becomes the prize — no AMM, no LP tokens.
- When the prediction period ends, **only the winning side can claim**.
- **Payouts** are proportional to the user’s share of the winning side.
- **Fees** — the house gets a small percentage of the pool

### 📊 Decentralized Resolution

- Outcome resolution is performed **entirely on-chain** using **Pyth VAAs (Verifiable Action Approvals)**.
- The final price is verified using Pyth’s oracle price feed at:
  - **Start time** of prediction
  - **End time** of prediction

### 💸 Claiming Rewards

- Users on the winning side can claim rewards **as soon as the round ends**.

