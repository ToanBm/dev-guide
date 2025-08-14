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
sleep 2
export PATH="$HOME/.foundry/bin:$PATH"
forge --version

sleep 2
foundryup

# --- Start Foundry Project ---
print_command "Initializing Foundry project..."
forge init --force --commit

while true; do

# --- Create Network & Token Contract ---
echo "Select Network:"
echo "1) Monad Testnet"
echo "2) Somnia Testnet"
echo "3) Fluent Devnet"
echo "4) 0G Galileo Testnet"
echo "5) Pharos Testnet"
read -p "Enter number: " rpc_choice

case $rpc_choice in
  1)
    DEFAULT_RPC="https://testnet-rpc.monad.xyz"
    CHAIN=10143
    VERIFIER=sourcify
    VERIFIER_URL="https://sourcify-api-monad.blockvision.org"
    SKIP_VERIFY=false
    ;;
  2)
    DEFAULT_RPC="https://dream-rpc.somnia.network"
    CHAIN=50312
    VERIFIER=blockscout
    VERIFIER_URL="https://shannon-explorer.somnia.network/api"
    SKIP_VERIFY=false
    ;;
  3)
    DEFAULT_RPC="https://rpc.dev.gblend.xyz/"
    CHAIN=20993
    VERIFIER=blockscout
    VERIFIER_URL="https://blockscout.dev.gblend.xyz/api/"
    SKIP_VERIFY=false
    ;;
  4)
    DEFAULT_RPC="https://evmrpc-testnet.0g.ai"
    CHAIN=80087
    VERIFIER=no
    VERIFIER_URL="no"
    SKIP_VERIFY=true
    ;;
  5)
    DEFAULT_RPC="https://testnet.dplabs-internal.com"
    CHAIN=688688
    VERIFIER=no
    VERIFIER_URL="no"
    SKIP_VERIFY=true
    ;;
  *)
    echo "❌ Invalid option!"
    exit 1
    ;;
esac

# --- Custom RPC option ---
read -p "Enter your custom RPC URL (Press Enter to use default: $DEFAULT_RPC): " CUSTOM_RPC
RPC_URL=${CUSTOM_RPC:-$DEFAULT_RPC}
echo "📡 Using RPC: $RPC_URL"

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

# --- Verify Contract ---
CONTRACT_NAME="src/MyToken.sol:MyToken"
if [ "$SKIP_VERIFY" != true ]; then
  echo "🔍 Verifying contract..."
  forge verify-contract \
    --rpc-url "$RPC_URL" \
    "$ADDRESS" \
    "$CONTRACT_NAME" \
    --verifier "$VERIFIER" \
    --verifier-url "$VERIFIER_URL"

  echo "✅ Verified on $VERIFIER!"
fi

sleep 3

# --- Prepare Address File ---
ADDRESS_FILE="addresses.txt"

if [ ! -f "$ADDRESS_FILE" ]; then
    echo "📂 Creating address file: $ADDRESS_FILE"
    touch $ADDRESS_FILE
fi

echo "📥 Please open the file: $ADDRESS_FILE"
echo "👉 Paste the recipient wallet addresses (one per line)."
read -p "Press Enter when you have finished pasting the addresses..."

ADDRESSES=($(cat $ADDRESS_FILE))
DECIMALS=18

# --- Multi Transfer ---
for TO_ADDRESS in "${ADDRESSES[@]}"; do
    NUM_TRANSFERS=$(( (RANDOM % 5) + 3 ))  # Random từ 3 đến 7 transaction

    echo "🚀 Starting transfers to $TO_ADDRESS - Total: $NUM_TRANSFERS"

    for i in $(seq 1 $NUM_TRANSFERS); do
        AMOUNT_DISPLAY=$(( (RANDOM % 99001) + 1000 ))  # Random amount: 1000 to 100000
        echo "🔢 Transfer #$i to $TO_ADDRESS: Amount (display): $AMOUNT_DISPLAY"

        AMOUNT_RAW=$(awk "BEGIN {printf \"%.0f\", $AMOUNT_DISPLAY * 10 ^ $DECIMALS}")

        cast send $ADDRESS \
            "transfer(address,uint256)" $TO_ADDRESS $AMOUNT_RAW \
            --private-key "$PRIVATE_KEY" \
            --rpc-url "$RPC_URL"

        SLEEP_TIME=$(( (RANDOM % 11) + 20 ))  # Sleep random từ 20 đến 30 giây
        echo "⏳ Sleeping $SLEEP_TIME sec..."
        sleep $SLEEP_TIME
    done

    echo "✅ Finished transfers to $TO_ADDRESS"
    echo "-----------------------------"
done

echo "✅ All transfers completed!"

read -p "Do you want to create another token? (y/n): " CONTINUE
if [[ "$CONTINUE" != "y" ]]; then
  echo "👋 Exiting..."
  break
fi

done
