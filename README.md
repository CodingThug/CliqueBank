# 🏦 Solidity Bank Contract – Full-Stack Smart Contract w/ Testing

## Overview

This project is a fully-functional **Solidity-based bank smart contract** built with:

- Account creation via ETH payment
- User information storage
- ETH deposit/withdrawal support
- Transaction logging
- Loan request + approval logic
- Foundry-based **fuzz testing**, **unit testing**, and **contract scripting**

---

## 🔧 Tech Stack

- **Solidity** `^0.8.24`
- **Foundry** – for compilation, testing, scripting
- **VS Code** – IDE
- **Git/GitHub** – version control and collaboration

---

## 💡 Features

### ✅ Core Features

- `setUserInfo`: Register an account by paying a small fee (`0.5 ether`)
- `makeDeposit`: Deposit ETH into your account
- `withdrawMyBalance`: Withdraw from your own balance
- `withdraw`: Only owner can withdraw total contract balance
- `updateUserInfo`: Update name, age, or marital status
- `getUserInfo`: View public user info
- `createUser`: Emits `UserRegistered` event
- `makeDeposit`: Emits `AllTransactions` event

### 🔁 Loan Feature (with test)

- `requestLoan`: User requests a loan
- `approveLoan`: Owner approves the loan
- `getLoanRequest`: Fetch loan request metadata

---

## 🧪 Foundry Testing

### 📁 Directory Structure
