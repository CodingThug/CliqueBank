// accounts.js
const { ethers } = window;

let contract;
const contractAddress = "<YOUR_ACTUAL_CONTRACT_ADDRESS>"; // Replace with deployed address from `forge create`
const contractABI = [/* Existing ABI unchanged */];

// Ensure ethers.js is available
if (!window.ethers) {
  console.error("ethers.js not found. Please include it via CDN or bundle.");
  alert("ethers.js is required. Please check your setup.");
}

// Connect the wallet and set up the contract
async function connectWallet() {
  if (!window.ethereum) {
    alert("Please install MetaMask to use this dApp");
    return;
  }

  // Ensure Monad Testnet is selected (replace with correct chainId)
  const monadTestnetChainId = "0x<MONAD_TESTNET_CHAINID>"; // Update with Monad Testnet chainId
  try {
    await window.ethereum.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId: monadTestnetChainId }],
    });
  } catch (switchError) {
    if (switchError.code === 4902) {
      alert("Please add Monad Testnet to MetaMask");
      return;
    }
    throw switchError;
  }

  await window.ethereum.request({ method: "eth_requestAccounts" });
  const provider = new ethers.providers.Web3Provider(window.ethereum);
  const signer = provider.getSigner();

  contract = new ethers.Contract(contractAddress, contractABI, signer);

  const address = await signer.getAddress();
  document.getElementById("status").textContent = `✅ Connected: ${address}`;
}

// Handle registration
document.getElementById("registerForm").addEventListener("submit", async function (e) {
  e.preventDefault();
  const name = document.getElementById("name").value;
  const age = parseInt(document.getElementById("age").value);
  const married = document.getElementById("married").value === "true";

  if (!contract) return alert("Connect wallet first");
  if (age < 1 || age > 150) return alert("Age must be between 1 and 150");
  if (name.length > 32) return alert("Name must be 32 characters or less");

  try {
    const tx = await contract.setUserInfo(age, name, married, {
      value: ethers.utils.parseEther("0.5"),
    });
    await tx.wait();
    document.getElementById("status").textContent = `✅ Registered ${name} (age ${age}, married: ${married})`;
  } catch (err) {
    console.error(err);
    let errorMsg = "Registration failed";
    if (err.reason) {
      errorMsg += `: ${err.reason}`;
    } else if (err.message.includes("insufficient funds")) {
      errorMsg += ": Insufficient ETH for 0.5 ETH fee";
    }
    document.getElementById("status").textContent = `❌ ${errorMsg}`;
  }
});

// Handle deposit
document.getElementById("depositForm").addEventListener("submit", async function (e) {
  e.preventDefault();
  const amount = document.getElementById("amount").value;

  if (!contract) return alert("Connect wallet first");
  if (isNaN(amount) || amount <= 0) return alert("Enter a valid deposit amount");

  try {
    const tx = await contract.makeDeposit({
      value: ethers.utils.parseEther(amount),
    });
    await tx.wait();
    document.getElementById("status").textContent = `💰 Deposited ${amount} ETH`;
  } catch (err) {
    console.error(err);
    let errorMsg = "Deposit failed";
    if (err.reason) {
      errorMsg += `: ${err.reason}`;
    } else if (err.message.includes("User not registered")) {
      errorMsg += ": Register first";
    }
    document.getElementById("status").textContent = `❌ ${errorMsg}`;
  }
});

document.getElementById("withdrawForm").addEventListener("submit", async function (e) {
  e.preventDefault();
  const amount = document.getElementById("withdrawAmount").value;
  if (!contract) return alert("Connect wallet first");
  if (isNaN(amount) || amount <= 0) return alert("Enter a valid withdrawal amount");
  try {
    const tx = await contract.withdrawMyBalance(ethers.utils.parseEther(amount));
    await tx.wait();
    document.getElementById("status").textContent = `💸 Withdrawn ${amount} ETH (after 2% fee)`;
  } catch (err) {
    console.error(err);
    let errorMsg = "Withdrawal failed";
    if (err.reason) errorMsg += `: ${err.reason}`;
    document.getElementById("status").textContent = `❌ ${errorMsg}`;
  }
});

// Add connect button listener
document.getElementById("connectBtn").addEventListener("click", connectWallet);