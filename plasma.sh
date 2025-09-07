#!/bin/bash
set -euo pipefail

echo -e "\033[0;34mPlasma ERC20 Auto Deployer\033[0m\n"

# ---------- Helper: prompt from /dev/tty or use env ----------
prompt_var() {
  # $1: var name, $2: prompt text, $3: silent? (true/false)
  local __var_name="$1"
  local __prompt="$2"
  local __silent="${3:-false}"

  # If already provided via ENV, keep it
  if [ -n "${!__var_name:-}" ]; then
    return
  fi

  # Read from /dev/tty to work even when script is piped
  if [ "$__silent" = "true" ]; then
    # require tty for silent input
    if [ -r /dev/tty ]; then
      # shellcheck disable=SC2162
      read -s -p "$__prompt" __val </dev/tty
      echo "" >/dev/tty
    else
      echo "No TTY available; please set $__var_name via environment variable." >&2
      exit 1
    fi
  else
    if [ -r /dev/tty ]; then
      # shellcheck disable=SC2162
      read -p "$__prompt" __val </dev/tty
    else
      echo "No TTY available; please set $__var_name via environment variable." >&2
      exit 1
    fi
  fi
  export "$__var_name"="${__val:-}"
}

# ---------- Ask inputs (ENV fallback) ----------
prompt_var TOKEN_NAME "Token name: " false
prompt_var TOKEN_SYMBOL "Token symbol: " false
prompt_var TOTAL_SUPPLY_HUMAN "Total supply (e.g. 1000000): " false
prompt_var PRIVATE_KEY "Private key (with or without 0x): " true

# Normalize PK → ensure 0x prefix and hex length
if [[ "${PRIVATE_KEY}" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
  :
elif [[ "${PRIVATE_KEY}" =~ ^[0-9a-fA-F]{64}$ ]]; then
  PRIVATE_KEY="0x${PRIVATE_KEY}"
else
  echo "Invalid PRIVATE_KEY. Expect 64 hex chars, optional 0x." >&2
  exit 1
fi

PROJECT_DIR="plasma-hardhat-erc20"
PLASMA_RPC="${PLASMA_RPC:-https://testnet-rpc.plasma.to}"
PLASMA_CHAIN_ID=9746

mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

# Init project (idempotent)
[ -f package.json ] || npm init -y >/dev/null

echo "Installing deps..."
npm i -D hardhat @nomicfoundation/hardhat-ethers ethers @openzeppelin/contracts dotenv >/dev/null

# Hardhat config (non-interactive)
cat > hardhat.config.js <<'EOF'
/** @type import('hardhat/config').HardhatUserConfig */
require('dotenv').config();
require('@nomicfoundation/hardhat-ethers');

function normalizePk(pk) {
  if (!pk) return undefined;
  return pk.startsWith('0x') ? pk : `0x${pk}`;
}
const PRIVATE_KEY = normalizePk(process.env.PRIVATE_KEY);
const RPC = process.env.PLASMA_RPC || 'https://testnet-rpc.plasma.to';

module.exports = {
  solidity: { version: "0.8.20", settings: { optimizer: { enabled: true, runs: 200 } } },
  networks: {
    plasmaTestnet: {
      url: RPC,
      chainId: 9746,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    },
  },
};
EOF

# Contract
mkdir -p contracts
cat > contracts/MyToken.sol <<'EOF'
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
EOF

# Deploy script
mkdir -p scripts
cat > scripts/deploy.js <<'EOF'
const { ethers } = require("hardhat");

async function main() {
  const name = process.env.TOKEN_NAME || "My Token";
  const symbol = process.env.TOKEN_SYMBOL || "MTK";
  const totalHuman = (process.env.TOTAL_SUPPLY_HUMAN || "1000000").replaceAll("_", "");
  const supply = ethers.parseUnits(totalHuman, 18);

  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const bal = await deployer.provider.getBalance(deployer.address);
  console.log("Deployer balance (wei):", bal.toString());

  const Token = await ethers.getContractFactory("MyToken");
  const token = await Token.deploy(name, symbol, supply);
  console.log("Tx:", token.deploymentTransaction().hash);

  await token.waitForDeployment();
  const addr = await token.getAddress();
  console.log("✅ Deployed at:", addr);
  console.log("Explorer:", `https://testnet.plasmascan.to/address/${addr}`);
  console.log("Name/Symbol/Supply:", name, symbol, totalHuman);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
EOF

# .env
cat > .env <<EOF
TOKEN_NAME=${TOKEN_NAME}
TOKEN_SYMBOL=${TOKEN_SYMBOL}
TOTAL_SUPPLY_HUMAN=${TOTAL_SUPPLY_HUMAN}
PRIVATE_KEY=${PRIVATE_KEY}
PLASMA_RPC=${PLASMA_RPC}
EOF

echo "Compiling..."
npx hardhat compile

echo "Deploying..."
npx hardhat run scripts/deploy.js --network plasmaTestnet

echo -e "\nDone."
