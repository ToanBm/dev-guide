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

# ===== 6) deploy.js (ghi ra .deployed_address để bash đọc) =====
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

if [ ! -f ".deployed_address" ]; then
  echo "Deploy seems to have failed (no .deployed_address)."
  exit 1
fi
ADDRESS="$(cat .deployed_address)"
echo "Deployed token address: $ADDRESS"

# ===== 8) Multi-Transfer (addresses.txt + cast send) =====
ADDRESS_FILE="addresses.txt"
DECIMALS=18

# Create file if missing
if [ ! -f "$ADDRESS_FILE" ]; then
  echo "📂 Creating address file: $ADDRESS_FILE"
  touch "$ADDRESS_FILE"
fi

echo "📥 Please open the file: $ADDRESS_FILE"
echo "👉 Paste the recipient wallet addresses (one per line)."

# Wait for user (prefer /dev/tty). If no TTY (e.g., curl|bash or CI), wait until file has at least 1 valid address.
if [ -r /dev/tty ]; then
  echo "✍️  Edit and save the file, then press Enter to continue..."
  # shellcheck disable=SC2162
  read _ </dev/tty
else
  echo "(No TTY detected) ⏳ Waiting until the file contains at least one valid EVM address..."
  # loop until a line matches 0x + 40 hex chars
  until grep -Eiq '^[[:space:]]*0x[0-9a-fA-F]{40}[[:space:]]*$' "$ADDRESS_FILE"; do
    sleep 2
  done
fi

# Load, sanitize & validate addresses
mapfile -t RAW_ADDRESSES < "$ADDRESS_FILE"
ADDRESSES=()
declare -A SEEN
for line in "${RAW_ADDRESSES[@]}"; do
  addr="$(echo "$line" | tr -d '\r' | xargs)"   # trim
  if [[ "$addr" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    # dedupe
    if [ -z "${SEEN[$addr]:-}" ]; then
      ADDRESSES+=("$addr")
      SEEN[$addr]=1
    fi
  fi
done

if [ ${#ADDRESSES[@]} -eq 0 ]; then
  echo "⚠️  No valid addresses found in $ADDRESS_FILE. Abort."
  exit 1
fi

# Helper: calc raw amount using local node + ethers (safer than awk for big ints)
calc_amount_raw() {
  local display="$1"
  node -e "const {ethers}=require('ethers');console.log(ethers.parseUnits(String($display), $DECIMALS).toString())"
}

echo "Starting multi-transfer..."
# Prefer foundry 'cast'; fallback to Node+ethers if not present
if command -v cast >/dev/null 2>&1; then
  echo "(Using foundry 'cast send')"
  for TO in "${ADDRESSES[@]}"; do
    NUM_TRANSFERS=$(( (RANDOM % 5) + 3 ))  # 3..7
    echo "🚀 Transfers to $TO - total: $NUM_TRANSFERS"
    for i in $(seq 1 "$NUM_TRANSFERS"); do
      AMOUNT_DISPLAY=$(( (RANDOM % 99001) + 1000 )) # 1000..100000
      AMOUNT_RAW="$(calc_amount_raw "$AMOUNT_DISPLAY")"
      echo "🔢 #$i -> $TO : $AMOUNT_DISPLAY (raw: $AMOUNT_RAW)"

      cast send "$ADDRESS" \
        "transfer(address,uint256)" "$TO" "$AMOUNT_RAW" \
        --private-key "$PRIVATE_KEY" \
        --rpc-url "$PLASMA_RPC"

      SLEEP_TIME=$(( (RANDOM % 11) + 20 )) # 20..30
      echo "⏳ Sleeping $SLEEP_TIME sec..."
      sleep "$SLEEP_TIME"
    done
    echo "✅ Finished transfers to $TO"
    echo "-----------------------------"
  done
else
  echo "(foundry 'cast' not found) Fallback to Node+ethers for transfers"
  # temp JS sender using ethers v5
  cat > scripts/send-many.js <<'JS'
require('dotenv').config();
const fs = require('fs');
const { ethers } = require('ethers');

async function main() {
  const rpc = process.env.PLASMA_RPC || "https://testnet-rpc.plasma.to";
  const pk  = process.env.PRIVATE_KEY;
  const tokenAddr = process.env.TOKEN_ADDRESS;
  const provider = new ethers.providers.JsonRpcProvider(rpc, { name: "plasma", chainId: 9746 });
  const wallet = new ethers.Wallet(pk, provider);

  const abi = ["function transfer(address to, uint256 value) public returns (bool)"];
  const token = new ethers.Contract(tokenAddr, abi, wallet);

  const lines = fs.readFileSync('addresses.txt','utf8').split(/\r?\n/).map(s=>s.trim()).filter(Boolean);
  const addrs = Array.from(new Set(lines.filter(a=>/^0x[0-9a-fA-F]{40}$/.test(a))));

  for (const to of addrs) {
    const num = Math.floor(Math.random()*5)+3; // 3..7
    console.log(`Transfers to ${to} - total: ${num}`);
    for (let i=1;i<=num;i++){
      const display = Math.floor(Math.random()*99001)+1000; // 1000..100000
      const raw = ethers.utils.parseUnits(String(display), 18);
      console.log(`#${i} -> ${to}: ${display} (raw ${raw.toString()})`);
      const tx = await token.transfer(to, raw);
      console.log(`tx: ${tx.hash}`);
      await tx.wait();
      const sleepSec = Math.floor(Math.random()*11)+20; // 20..30
      console.log(`sleep ${sleepSec}s...`);
      await new Promise(r=>setTimeout(r, sleepSec*1000));
    }
  }
  console.log("All transfers completed.");
}
main().catch(e=>{console.error(e);process.exit(1);});
JS

  TOKEN_ADDRESS="$ADDRESS" node scripts/send-many.js
fi

echo "✅ All transfers completed!"

# Optional loop like your snippet
if $have_tty; then
  read -p "Do you want to create another token? (y/n): " CONTINUE
  if [[ "$CONTINUE" != "y" ]]; then
    echo "👋 Exiting..."
  fi
fi
