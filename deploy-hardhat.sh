#!/bin/bash

BOLD=$(tput bold)
RESET=$(tput sgr0)
YELLOW=$(tput setaf 3)

print_command() {
  echo -e "${BOLD}${YELLOW}$1${RESET}"
}

print_command "🛠 Setting up Hardhat project..."

npm install -g npm@latest > /dev/null
npm init -y > /dev/null
npm install --save-dev hardhat @nomicfoundation/hardhat-toolbox dotenv > /dev/null

npx hardhat init --force <<EOF
1
EOF

echo "🌐 Select Network:"
echo "1) Monad Testnet"
echo "2) Somnia Testnet"
echo "3) Fluent Devnet"
echo "4) 0G Galileo Testnet"
read -p "Enter number: " rpc_choice

case $rpc_choice in
  1)
    RPC_URL="https://testnet-rpc.monad.xyz"
    CHAIN=10143
    NETWORK_NAME="monadTestnet"
    API_URL="https://sourcify-api-monad.blockvision.org"
    EXPLORER_URL="https://testnet.monadexplorer.com"
    SKIP_VERIFY=false
    ;;
  2)
    RPC_URL="https://dream-rpc.somnia.network"
    CHAIN=50312
    NETWORK_NAME="somniaTestnet"
    API_URL="https://shannon-explorer.somnia.network/api"
    EXPLORER_URL="https://shannon-explorer.somnia.network"
    SKIP_VERIFY=false
    ;;
  3)
    RPC_URL="https://rpc.dev.gblend.xyz/"
    CHAIN=20993
    NETWORK_NAME="fluentDevnet"
    API_URL="https://blockscout.dev.gblend.xyz/api/"
    EXPLORER_URL="https://blockscout.dev.gblend.xyz"
    SKIP_VERIFY=false
    ;;
  4)
    RPC_URL="https://evmrpc-testnet.0g.ai"
    CHAIN=80087
    NETWORK_NAME="zeroGTestnet"
    API_URL=""
    EXPLORER_URL=""
    SKIP_VERIFY=true
    ;;
  *)
    echo "❌ Invalid option!"
    exit 1
    ;;
esac

read -p "Enter token name: " TOKEN_NAME
read -p "Enter token symbol (e.g. ABC): " TOKEN_SYMBOL
read -p "Enter total supply (default: 1000000000): " TOTAL_SUPPLY
TOTAL_SUPPLY=${TOTAL_SUPPLY:-1000000000}
read -p "Enter your EVM private key (no 0x): " PRIVATE_KEY

mkdir -p contracts
cat <<EOF > contracts/MyToken.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MyToken {
    string public name = "$TOKEN_NAME";
    string public symbol = "$TOKEN_SYMBOL";
    uint8 public decimals = 18;
    uint256 public totalSupply = $TOTAL_SUPPLY * (10 ** uint256(decimals));
    mapping(address => uint256) public balanceOf;

    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor() {
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
}
EOF

rm -f contracts/Lock.sol

cat <<EOF > .env
PRIVATE_KEY=$PRIVATE_KEY
RPC_URL=$RPC_URL
CHAIN=$CHAIN
NETWORK_NAME=$NETWORK_NAME
SKIP_VERIFY=$SKIP_VERIFY
EOF

cat <<EOF > hardhat.config.js
require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

module.exports = {
  solidity: "0.8.20",
  networks: {
    [process.env.NETWORK_NAME]: {
      url: process.env.RPC_URL,
      chainId: parseInt(process.env.CHAIN),
      accounts: ["0x" + process.env.PRIVATE_KEY]
    }
  },
  etherscan: {
    apiKey: "DUMMY_API_KEY",
    customChains: [
      {
        network: "monadTestnet",
        chainId: 10143,
        urls: {
          apiURL: "https://sourcify-api-monad.blockvision.org",
          browserURL: "https://testnet.monadexplorer.com"
        }
      },
      {
        network: "somniaTestnet",
        chainId: 50312,
        urls: {
          apiURL: "https://shannon-explorer.somnia.network/api",
          browserURL: "https://shannon-explorer.somnia.network"
        }
      },
      {
        network: "fluentDevnet",
        chainId: 20993,
        urls: {
          apiURL: "https://blockscout.dev.gblend.xyz/api/",
          browserURL: "https://blockscout.dev.gblend.xyz"
        }
      }
    ]
  }
};
EOF


mkdir -p scripts
cat <<'EOF' > scripts/deploy.js
const hre = require("hardhat");
const fs = require("fs");

async function main() {
  const MyToken = await hre.ethers.getContractFactory("MyToken");
  const token = await MyToken.deploy();
  await token.waitForDeployment();
  const address = token.target;
  console.log("✅ Deployed to:", address);
  fs.writeFileSync("contract-address.txt", address);

  if (process.env.SKIP_VERIFY !== "true") {
    console.log("🔍 Verifying contract...");
    try {
      await hre.run("verify:verify", {
        address,
        constructorArguments: []
      });
      console.log("✅ Verified successfully!");
    } catch (err) {
      console.error("❌ Verification failed:", err.message);
    }
  } else {
    console.log("ℹ️ Skipping verification");
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
EOF

cat <<'EOF' > scripts/transfer.js
const hre = require("hardhat");
const fs = require("fs");

async function main() {
  const address = fs.readFileSync("contract-address.txt", "utf8").trim();
  const token = await hre.ethers.getContractAt("MyToken", address);

  const DECIMALS = 18;
  const NUM_TRANSFERS = parseInt(process.env.NUM_TRANSFERS || "3");

  for (let i = 1; i <= NUM_TRANSFERS; i++) {
    const wallet = hre.ethers.Wallet.createRandom();
    const to = wallet.address;
    const amount = BigInt((Math.floor(Math.random() * 99001) + 1000)) * 10n ** BigInt(DECIMALS);

    console.log(`Transfer #${i} to ${to}, amount: ${amount}`);
    const tx = await token.transfer(to, amount);
    await tx.wait();

    const sleep = Math.floor(Math.random() * 11) + 20;
    console.log(`Sleeping ${sleep} sec...`);
    await new Promise(res => setTimeout(res, sleep * 1000));
  }

  console.log("✅ All transfers completed!");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
EOF

print_command "🚀 Deploying contract..."
npx hardhat run scripts/deploy.js --network "$NETWORK_NAME"

read -p "How many transfers do you want to make? " NUM_TRANSFERS
export NUM_TRANSFERS

print_command "🔁 Executing transfers..."
npx hardhat run scripts/transfer.js --network "$NETWORK_NAME"

print_command "🎉 Done."
