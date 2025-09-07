#!/bin/bash
set -e

# Logo
echo -e "\033[0;34m"
echo "Plasma ERC20 Auto Deployer"
echo -e "\e[0m"

# -------- helpers (ENV-first, then prompt if TTY) --------
have_tty=false
if [ -t 1 ] && [ -r /dev/tty ]; then
  have_tty=true
fi

ask() {
  # $1 var name, $2 prompt, $3 silent? (true/false)
  local var="$1" prompt="$2" silent="${3:-false}"
  # If provided via ENV, keep it
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

# -------- Step 1: Install hardhat + deps (your way) --------
echo "Install Hardhat..."
npm init -y >/dev/null
npm install --save-dev hardhat @nomiclabs/hardhat-ethers ethers@^5 @openzeppelin/contracts >/dev/null
echo "Install dotenv..."
npm install dotenv >/dev/null

# -------- Step 2: Choose 'Create an empty hardhat.config.js' (option 3) --------
echo "Creating project with an empty hardhat.config.js..."
yes "3" | npx hardhat init >/dev/null

# -------- Step 3: Create ERC20 contract (name/symbol via constructor) --------
echo "Create ERC20 contract..."
mkdir -p contracts
cat > contracts/MyToken.sol <<'EOL'
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
EOL

# -------- Step 4: Create .env --------
echo "Create .env file..."
cat > .env <<EOF
TOKEN_NAME=${TOKEN_NAME}
TOKEN_SYMBOL=${TOKEN_SYMBOL}
TOTAL_SUPPLY=${TOTAL_SUPPLY}
PRIVATE_KEY=${PRIVATE_KEY}
PLASMA_RPC=${PLASMA_RPC:-https://testnet-rpc.plasma.to}
EOF

# -------- Step 5: hardhat.config.js (Plasma testnet) --------
echo "Creating new hardhat.config.js..."
rm -f hardhat.config.js
cat > hardhat.config.js <<'EOL'
/** @type import('hardhat/config').HardhatUserConfig */
require('dotenv').config();
require("@nomiclabs/hardhat-ethers");

// normalize pk to 0x...
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
EOL

# -------- Step 6: deploy script (ethers v5 style) --------
echo "Creating deploy script..."
mkdir -p scripts
cat > scripts/deploy.js <<'EOL'
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

  console.log("✅ Token deployed to:", token.address);
  console.log("Explorer:", `https://testnet.plasmascan.to/address/${token.address}`);
  console.log("Name/Symbol/Supply:", name, symbol, totalHuman);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
EOL

# -------- Step 7: Compile --------
echo "Compile your contracts..."
npx hardhat compile

# -------- Step 8: Deploy --------
echo "Deploy your contracts..."
npx hardhat run scripts/deploy.js --network plasma

echo "Thank you!"
