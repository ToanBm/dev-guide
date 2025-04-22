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

# --- Start Foundry Project ---
print_command "Initializing Foundry project..."
forge init --force --no-commit

# --- Create Network & Token Contract ---
echo "Select Network:"
echo "1) Monad testnet"
echo "2) Somnia testnet"
echo "3) ....."
echo "4) Custom RPC"
read -p "Enter number: " rpc_choice

case $rpc_choice in
  1)
    RPC_URL="https://rpc.monad.xyz"
    ;;
  2)
    RPC_URL="https://dream-rpc.somnia.network"
    ;;
  3)
    RPC_URL="......"
    ;;
  4)
    read -p "Enter your custom RPC URL: " RPC_URL
    ;;
  *)
    echo "❌ Invalid option!"
    exit 1
    ;;
esac

read -p "Enter token name: " TOKEN_NAME
read -p "Enter token symbol (e.g. ABC): " TOKEN_SYMBOL
read -p "Enter total supply (Enter to choose: 1,000,000,000): " TOTAL_SUPPLY
TOTAL_SUPPLY=${TOTAL_SUPPLY:-1000000000}

rm src/Counter.sol

cat <<EOF > src/MyToken.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

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
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function mint(uint256 amount) public {
        uint256 mintAmount = amount * (10 ** uint256(decimals));
        totalSupply += mintAmount;
        balanceOf[msg.sender] += mintAmount;
        emit Transfer(address(0), msg.sender, mintAmount);
    }
}
EOF

# --- .env File ---
read -p "Enter your EVM wallet private key (without 0x): " PRIVATE_KEY

print_command "Generating .env file..."
cat <<EOF > .env
PRIVATE_KEY=$PRIVATE_KEY
RPC_URL=$RPC_URL
EOF

export $(grep -v '^#' .env | xargs)

# --- Deploy Contract ---
print_command "Deploying contract..."
ADDRESS=$(forge create src/MyToken.sol:MyToken \
  --private-key "$PRIVATE_KEY" \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --json | jq -r '.deployedTo')

echo "$ADDRESS" > contract-address.txt
echo "✅ Deployed to: $ADDRESS"

# --- Choose Network for Verification ---
echo "Choose network to verify:"
echo "0) Skip verification"
echo "1) Monad testnet"
echo "2) Somnia testnet"
echo "3) ...."
read -p "Enter number: " choice

case $choice in
  0)
    echo "Skipping verification..."
    exit 0
    ;;
  1)
    CHAIN=10143
    VERIFIER=sourcify
    VERIFIER_URL="https://sourcify-api-monad.blockvision.org"
    ;;
  2)
    CHAIN=50312
    VERIFIER=blockscout
    VERIFIER_URL="https://shannon-explorer.somnia.network/api"
    ;;
  3)
    CHAIN=11155111
    VERIFIER=etherscan
    VERIFIER_URL="https://api-sepolia.etherscan.io/api"
    ;;
  *)
    echo "❌ Invalid option!"
    exit 1
    ;;
esac

# --- Verify Contract ---
CONTRACT_NAME="src/MyToken.sol:MyToken"
echo "🔍 Verifying contract..."
forge verify-contract \
  --rpc-url "$RPC_URL" \
  "$ADDRESS" \
  "$CONTRACT_NAME" \
  --verifier "$VERIFIER" \
  --verifier-url "$VERIFIER_URL"

echo "✅ Contract verified!"

sleep 3

# --- Multi Transfer ---
read -p "How many transfers do you want to make? " NUM_TRANSFERS
DECIMALS=18

for i in $(seq 1 $NUM_TRANSFERS); do
    TO_ADDRESS="0x$(tr -dc 'a-f0-9' < /dev/urandom | head -c 40)"
    AMOUNT_DISPLAY=$(( (RANDOM % 99001) + 1000 ))
    echo "🔢 Transfer #$i: Amount (display): $AMOUNT_DISPLAY"

    AMOUNT_RAW=$(echo "$AMOUNT_DISPLAY * 10^$DECIMALS" | bc)

    cast send $ADDRESS \
        "transfer(address,uint256)" $TO_ADDRESS $AMOUNT_RAW \
        --private-key "$PRIVATE_KEY" \
        --rpc-url "$RPC_URL"

    SLEEP_TIME=$(( (RANDOM % 11) + 20 ))
    echo "⏳ Sleeping $SLEEP_TIME sec..."
    sleep $SLEEP_TIME
done

echo "✅ All transfers completed!"
