#!/bin/bash
set -euo pipefail

# ===== UI =====
echo -e "\033[0;34m"
echo "Plasma ERC20 Auto Deployer"
echo -e "\e[0m"

# ===== Ask inputs =====
read -r -p "Token name: " TOKEN_NAME
read -r -p "Token symbol: " TOKEN_SYMBOL
read -r -p "Total supply (human, e.g. 1000000): " TOTAL_SUPPLY_HUMAN
read -r -s -p "Private key (with or without 0x): " PRIVATE_KEY_INPUT
echo ""

# Normalize PK (ensure 0x prefix)
if [[ "$PRIVATE_KEY_INPUT" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
  PRIVATE_KEY="$PRIVATE_KEY_INPUT"
elif [[ "$PRIVATE_KEY_INPUT" =~ ^[0-9a-fA-F]{64}$ ]]; then
  PRIVATE_KEY="0x$PRIVATE_KEY_INPUT"
else
  echo "Invalid private key format. Expect 64 hex chars, optional 0x."
  exit 1
fi

# ===== Constants =====
PROJECT_DIR="plasma-hardhat-erc20"
PLASMA_RPC_DEFAULT="https://testnet-rpc.plasma.to"  # Plasma Testnet RPC
PLASMA_CHAIN_ID=9746
PLASMA_EXPLORER="https://testnet.plasmascan.to"

# ===== Create project folder =====
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

# ===== Init npm & install deps =====
if [ ! -f "package.json" ]; then
  npm init -y >/dev/null
fi

echo "Installing Hardhat + plugins + OZ + dotenv..."
# Use ethers v6 with official plugin
npm i -D hardhat @nomicfoundation/hardhat-ethers ethers @openzeppelin/contracts dotenv >/dev/null

# ===== Hardhat minimal config (no interactive init) =====
cat > hardhat.config.js <<'EOF'
/** @type import('hardhat/config').HardhatUserConfig */
require('dotenv').config();
require('@nomicfoundation/hardhat-ethers');

function normalizePk(pk) {
  if (!pk) return undefined;
  return pk.startsWith('0x') ? pk : `0x${pk}`;
}

const PRIVATE_KEY = normalizePk(process.env.PRIVATE_KEY);
const PLASMA_RPC = process.env.PLASMA_RPC || 'https://testnet-rpc.plasma.to';

module.exports = {
  solidity: {
    version: "0.8.20",
    settings: { optimizer: { enabled: true, runs: 200 } }
  },
  networks: {
    plasmaTestnet: {
      url: PLASMA_RPC,
      chainId: 9746,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    },
  }
};
EOF

# ===== Contracts =====
mkdir -p contracts
cat > contracts/MyToken.sol <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Simple ERC20 where initial supply (18 decimals) is minted to deployer
contract MyToken is ERC20 {
    constructor(string memory _name, string memory _symbol, uint256 initialSupply)
        ERC20(_name, _symbol)
    {
        _mint(msg.sender, initialSupply);
    }
}
EOF

# ===== Deploy script =====
mkdir -p scripts
cat > scripts/deploy.js <<'EOF'
const { ethers } = require("hardhat");

async function main() {
  const name = process.env.TOKEN_NAME || "My Token";
  const symbol = process.env.TOKEN_SYMBOL || "MTK";
  const totalHuman = (process.env.TOTAL_SUPPLY_HUMAN || "1000000").replaceAll("_", "");
  const supply = ethers.parseUnits(totalHuman, 18); // 18 decimals

  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const bal = await deployer.provider.getBalance(deployer.address);
  console.log("Deployer balance (wei):", bal.toString());

  const Token = await ethers.getContractFactory("MyToken");
  const token = await Token.deploy(name, symbol, supply);
  console.log("Tx hash:", token.deploymentTransaction().hash);

  await token.waitForDeployment();
  const addr = await token.getAddress();

  console.log("✅ Token deployed at:", addr);
  console.log("Explorer:", `https://testnet.plasmascan.to/address/${addr}`);
  console.log("Name/Symbol/Supply(18d):", name, symbol, totalHuman);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
EOF

# ===== .env =====
cat > .env <<EOF
# ==== User inputs ====
TOKEN_NAME=${TOKEN_NAME}
TOKEN_SYMBOL=${TOKEN_SYMBOL}
TOTAL_SUPPLY_HUMAN=${TOTAL_SUPPLY_HUMAN}
PRIVATE_KEY=${PRIVATE_KEY}

# ==== Network ====
PLASMA_RPC=${PLASMA_RPC_DEFAULT}
EOF

# ===== Compile & Deploy =====
echo "Compiling..."
npx hardhat compile

echo "Deploying to Plasma Testnet..."
npx hardhat run scripts/deploy.js --network plasmaTestnet

echo ""
echo "Done."
echo "If needed, verify fields in .env then re-run: npx hardhat run scripts/deploy.js --network plasmaTestnet"
