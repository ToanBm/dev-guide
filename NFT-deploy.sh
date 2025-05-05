#!/bin/bash

BOLD=$(tput bold)
RESET=$(tput sgr0)
YELLOW=$(tput setaf 3)

# Logo
echo     "*********************************************"
echo     "Github: https://github.com/ToanBm"
echo     "X: https://x.com/buiminhtoan1985"
echo -e "\e[0m"

print_command() {
  echo -e "${BOLD}${YELLOW}$1${RESET}"
}

# --- Install Foundry ---
print_command "Installing Foundry..."
curl -L https://foundry.paradigm.xyz | bash
export PATH="$HOME/.foundry/bin:$PATH"
sleep 2
foundryup

# --- Init Project ---
print_command "Initializing Foundry project..."
forge init --force --no-commit

# --- Select Network ---
echo "Select Network:"
echo "1) Monad Testnet"
echo "2) Somnia Testnet"
echo "3) Fluent Devnet"
echo "4) 0G Galileo Testnet"
read -p "Enter number: " rpc_choice

case $rpc_choice in
  1)
    RPC_URL="https://testnet-rpc.monad.xyz"
    CHAIN=10143
    ;;
  2)
    RPC_URL="https://dream-rpc.somnia.network"
    CHAIN=50312
    ;;
  3)
    RPC_URL="https://rpc.dev.gblend.xyz/"
    CHAIN=20993
    ;;
  4)
    RPC_URL="https://evmrpc-testnet.0g.ai"
    CHAIN=80087
    ;;
  *)
    echo "❌ Invalid option!"
    exit 1
    ;;
esac

# --- NFT Config ---
read -p "Enter NFT name: " NFT_NAME
read -p "Enter NFT symbol (e.g. NFT): " NFT_SYMBOL
read -p "Enter max supply (default 1000): " MAX_SUPPLY
MAX_SUPPLY=${MAX_SUPPLY:-1000}
read -p "Enter mint price in ETH (default 0.01): " MINT_PRICE
MINT_PRICE=${MINT_PRICE:-0.01}
read -p "Enter baseURI (e.g. https://gateway.pinata.cloud/ipfs/xxxxx/): " BASE_URI

# --- Contract ---
print_command "Writing MarketNFT.sol..."
cat <<EOF > src/MarketNFT.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MarketNFT is ERC721Enumerable, Ownable {
    uint256 public maxSupply = $MAX_SUPPLY;
    uint256 public mintPrice = ${MINT_PRICE} ether;
    uint256 public nextTokenId;
    string public baseURI = "$BASE_URI";

    constructor() ERC721("$NFT_NAME", "$NFT_SYMBOL") Ownable(msg.sender) {}

    function mint() external payable {
        require(nextTokenId < maxSupply, "Sold out");
        require(msg.value >= mintPrice, "Insufficient payment");
        _safeMint(msg.sender, nextTokenId);
        nextTokenId++;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_exists(tokenId), "Nonexistent token");
        return string(abi.encodePacked(baseURI, _toString(tokenId), ".json"));
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
EOF

# --- Deploy ---
read -p "Enter your EVM wallet private key (without 0x): " PRIVATE_KEY
print_command "Deploying contract..."
export PRIVATE_KEY=$PRIVATE_KEY
export RPC_URL=$RPC_URL

forge create src/MarketNFT.sol:MarketNFT \
  --private-key "$PRIVATE_KEY" \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --json | tee deploy-result.json

ADDRESS=$(jq -r '.deployedTo' deploy-result.json)
echo "✅ Deployed to: $ADDRESS"
echo "$ADDRESS" > contract-address.txt
