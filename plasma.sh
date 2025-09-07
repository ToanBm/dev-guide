#!/bin/bash
set -e

# ===== UI =====
echo -e "\033[0;34m"
echo "Plasma ERC20 Auto Deployer + Multi-Transfer"
echo -e "\e[0m"

# -------- helpers (ENV-first, then prompt if TTY) --------
have_tty=false
if [ -t 1 ] && [ -r /dev/tty ]; then
  have_tty=true
fi

ask() {
  # $1 var name, $2 prompt, $3 silent? (true/false)
  local var="$1" prompt="$2" silent="${3:-false}"
  if [ -n "${!var:-}" ]; then return 0; fi
  if $have_tty; then
    if [ "$silent" = "true" ]; then
      # shellcheck disable=SC2162
      read -s -p "$prompt" val </dev/tty
      echo "" >/dev/tty
    else
      # shellcheck disable=SC2162
      read -p "$prompt" val </dev/tty
    fi
    export "$var"="$val"
  else
    echo "No TTY available; please set $var as environment variable." >&2
    exit 1
  fi
}

# -------- ask for inputs (ENV fallback) --------
ask TOKEN_NAME   "Token name: " false
ask TOKEN_SYMBOL "Token symbol: " false
ask TOTAL_SUPPLY "Total supply (human, e.g. 1000000): " false
ask PRIVATE_KEY  "Private key (with or without 0x): " true

# normalize private key
if [[ "$PRIVATE_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
  :
elif [[ "$PRIVATE_KEY" =~ ^[0-9a-fA-F]{64}$ ]]; then
  PRIVATE_KEY="0x$PRIVATE_KEY"
else
  echo "Invalid PRIVATE_KEY. Expect 64 hex chars (with/without 0x)." >&2
  exit 1
fi

PLASMA_RPC="${PLASMA_RPC:-https://testnet-rpc.plasma.to}"
CHAIN_ID=9746

# ===== 1) Init project & install deps (pinned to avoid ERESOLVE) =====
npm init -y >/dev/null

echo "Installing Hardhat (v2) & deps..."
npm install --save-dev \
  hardhat@2.26.3 \
  @nomiclabs/hardhat-ethers@2.2.3 \
  ethers@5.7.2 \
  @openzeppelin/contracts@4 >/dev/null

echo "Install dotenv..."
npm install dotenv >/dev/null

# ===== 2) Make empty hardhat.config.js (your way) =====
echo "Creating project with an empty hardhat.config.js..."
if ! yes "3" | npx hardhat init >/dev/null 2>&1; then
  echo "(hardhat init skipped/fallback)"
fi

# ===== 3) Contract =====
echo "Create ERC20 contract..."
mkdir -p contracts
cat > contracts/MyToken.sol <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Simple ERC20 (18 decimals). Mints all initial supply to deployer.
contract MyToken is ERC20 {
    constructor(string memory _name, string memory _symbol, uint256 initialSupply)
        ERC20(_name, _symbol)
    {
        _mint(msg.sender, initialSupply);
    }
}
SOL

# ===== 4) .env =====
echo "Create .env..."
cat > .env <<EOF
TOKEN_NAME=${TOKEN_NAME}
TOKEN_SYMBOL=${TOKEN_SYMBOL}
TOTAL_SUPPLY=${TOTAL_SUPPLY}
PRIVATE_KEY=${PRIVATE_KEY}
PLASMA_RPC=${PLASMA_RPC}
EOF

# ===== 5) hardhat.config.js (Plasma testnet) =====
echo "Creating new hardhat.config.js..."
rm -f hardhat.config.js
cat > hardhat.config.js <<'JS'
/** @type import('hardhat/config').HardhatUserConfig */
require('dotenv').config();
require("@nomiclabs/hardhat-ethers");

function normalizePk(pk) {
  if (!pk) return undefined;
  return pk.startsWith('0x') ? pk : `0x${pk}`;
}

const PRIVATE_KEY = normalizePk(process.env.PRIVATE_KEY);
const PLASMA_RPC = process.env.PLASMA_RPC || "https://testnet-rpc.plasma.to";

module.exports = {
  solidity: "0.8.20",
  networks: {
    plasma: {
      url: PLASMA_RPC,
      chainId: 9746,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    },
  }
};
JS

# ===== 6) deploy.js (write .deployed_address for bash to consume) =====
echo "Creating deploy script..."
mkdir -p scripts
cat > scripts/deploy.js <<'JS'
const fs = require('fs');
const path = require('path');
const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();

  const name = process.env.TOKEN_NAME || "My Token";
  const symbol = process.env.TOKEN_SYMBOL || "MTK";
  const totalHuman = String(process.env.TOTAL_SUPPLY || "1000000").replace(/_/g, "");
  const initialSupply = ethers.utils.parseUnits(totalHuman, "ether"); // 18 decimals

  console.log("Deployer:", deployer.address);
  const bal = await deployer.provider.getBalance(deployer.address);
  console.log("Deployer balance (wei):", bal.toString());

  const Token = await ethers.getContractFactory("MyToken");
  const token = await Token.deploy(name, symbol, initialSupply);
  await token.deployed();

  const addr = token.address;
  console.log("✅ Token deployed to:", addr);
  console.log("Explorer:", `https://testnet.plasmascan.to/address/${addr}`);
  console.log("Name/Symbol/Supply:", name, symbol, totalHuman);

  fs.writeFileSync(path.join(process.cwd(), ".deployed_address"), addr, "utf8");
}
main().catch((error) => {
  console.error(error);
  process.exit(1);
});
JS

# ===== 7) Compile & Deploy =====
echo "Compile your contracts..."
npx hardhat compile

echo "Deploy your contracts..."
npx hardhat run scripts/deploy.js --network plasma

# === Persist deployed address to .env (auto) ===
# Read the address from .deployed_address, validate, then upsert .env
if [ ! -f .deployed_address ]; then
  echo "❌ Deploy didn't create .deployed_address. Abort."
  exit 1
fi

ADDRESS="$(tr -d '\r' < .deployed_address | xargs)"
if [[ ! "$ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  echo "❌ Invalid address in .deployed_address: $ADDRESS"
  exit 1
fi

echo "Deployed token address: $ADDRESS"

if grep -q '^TOKEN_ADDRESS=' .env; then
  sed -i.bak "s|^TOKEN_ADDRESS=.*|TOKEN_ADDRESS=${ADDRESS}|g" .env
else
  printf "\nTOKEN_ADDRESS=%s\n" "$ADDRESS" >> .env
fi
echo "📝 TOKEN_ADDRESS saved to .env: $ADDRESS"

# ===== 8) Multi-Transfer (pure Hardhat) =====
ADDRESS_FILE="addresses.txt"

# Prepare addresses.txt
if [ ! -f "$ADDRESS_FILE" ]; then
  echo "📂 Creating address file: $ADDRESS_FILE"
  touch "$ADDRESS_FILE"
fi

echo "📥 Please open the file: $ADDRESS_FILE"
echo "👉 Paste the recipient wallet addresses (one per line)."

# Wait for user (prefer /dev/tty). If no TTY, wait until file has at least 1 valid address
if [ -r /dev/tty ]; then
  echo "✍️  Edit and save the file, then press Enter to continue..."
  read _ </dev/tty
else
  echo "(No TTY) ⏳ Waiting until the file contains at least one valid EVM address..."
  until grep -Eiq '^[[:space:]]*0x[0-9a-fA-F]{40}[[:space:]]*$' "$ADDRESS_FILE"; do
    sleep 2
  done
fi

# Create transfer script (idempotent)
mkdir -p scripts
cat > scripts/transfer-many.js <<'JS'
// scripts/transfer-many.js
require('dotenv').config();
const fs = require('fs');
const path = require('path');

const DECIMALS = 18;
const MIN_TRANSFERS = 3;
const MAX_TRANSFERS = 7;
const MIN_AMOUNT = 1000;      // inclusive
const MAX_AMOUNT = 100000;    // inclusive
const MIN_SLEEP = 20;         // seconds
const MAX_SLEEP = 40;         // seconds

const ADDR_RE = /^0x[0-9a-fA-F]{40}$/;

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }
function randInt(min, max) { return Math.floor(Math.random() * (max - min + 1)) + min; }

async function main() {
  const hre = require('hardhat');
  const { ethers } = hre;

  const tokenAddress = process.env.TOKEN_ADDRESS;
  const symbol = process.env.TOKEN_SYMBOL || 'TOKEN';
  if (!tokenAddress || !ADDR_RE.test(tokenAddress)) {
    throw new Error('Missing or invalid TOKEN_ADDRESS in .env');
  }

  const [signer] = await ethers.getSigners();
  console.log('👤 Sender:', signer.address);

  // Minimal ERC20 ABI
  const abi = ['function transfer(address to,uint256 value) external returns (bool)'];
  const token = new ethers.Contract(tokenAddress, abi, signer);

  // Load, sanitize & dedupe addresses
  const file = path.join(process.cwd(), 'addresses.txt');
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/).map(s => s.trim()).filter(Boolean);
  const addrs = Array.from(new Set(lines.filter(a => ADDR_RE.test(a))));
  if (addrs.length === 0) {
    console.log('⚠️  No valid addresses found in addresses.txt');
    process.exit(1);
  }

  for (const to of addrs) {
    const num = randInt(MIN_TRANSFERS, MAX_TRANSFERS);
    console.log(`🚀 Starting transfers to ${to} — Total: ${num}`);
    for (let i = 1; i <= num; i++) {
      const amountDisplay = randInt(MIN_AMOUNT, MAX_AMOUNT);        // integer amount
      const amountRaw = ethers.utils.parseUnits(String(amountDisplay), DECIMALS);
      console.log(`💸 #${i} → ${to}: ${amountDisplay} ${symbol}`);
      const tx = await token.transfer(to, amountRaw);
      console.log(`🧾 tx: ${tx.hash}`);
      const sleepSec = randInt(MIN_SLEEP, MAX_SLEEP);               // 20..40 seconds
      console.log(`⏳ Sleeping ${sleepSec}s...`);
      await sleep(sleepSec * 1000);
    }
    console.log(`✅ Finished transfers to ${to}`);
    console.log('-----------------------------');
  }
  console.log('✅ All transfers completed!');
}
main().catch((e) => { console.error(e); process.exit(1); });
JS

# Run with Hardhat (ethers v5)
npx hardhat run scripts/transfer-many.js --network plasma

# Optional loop like your snippet
if $have_tty; then
  read -p "Do you want to create another token? (y/n): " CONTINUE
  if [[ "$CONTINUE" != "y" ]]; then
    echo "👋 Exiting..."
  fi
fi
