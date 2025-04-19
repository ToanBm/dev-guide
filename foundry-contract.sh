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

# --- Nhập RPC URL ---
read -p "🔗 Enter your RPC URL (e.g. https://rpc.dev.gblend.xyz): " RPC_URL

# --- Install Foundry ---
print_command "Installing Foundry..."
curl -L https://foundry.paradigm.xyz | bash
export PATH="$HOME/.foundry/bin:$PATH"

sleep 2
foundryup

# --- Start Foundry Project ---
print_command "Initializing Foundry project..."
forge init --force

# --- Create Token Contract ---
read -p "Enter token name: " TOKEN_NAME
read -p "Enter token symbol (e.g. ABC): " TOKEN_SYMBOL
read -p "Enter total supply (e.g. 1000000): " TOTAL_SUPPLY

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

sleep 2

# --- Verify Contract ---
ADDRESS=$(cat contract-address.txt)

print_command "Verifying contract..."
forge verify-contract \
  --rpc-url "$RPC_URL" \
  "$ADDRESS" \
  src/MyToken.sol:MyToken \
  --verifier blockscout \
  --verifier-url https://blockscout.dev.gblend.xyz/api/

echo "✅ Verified!"
echo "🔗 https://blockscout.dev.gblend.xyz/address/$ADDRESS"

# --- Transfer Token ---
TO_ADDRESS="0x$(tr -dc 'a-f0-9' < /dev/urandom | head -c 40)"
AMOUNT_DISPLAY=$(( (RANDOM % 99001) + 1000 ))
echo "🔢 Amount (display): $AMOUNT_DISPLAY"

AMOUNT_RAW=$(echo "$AMOUNT_DISPLAY * 10^18" | bc)
echo "🔢 Raw amount to send: $AMOUNT_RAW"

cast send $ADDRESS \
  "transfer(address,uint256)" $TO_ADDRESS $AMOUNT_RAW \
  --private-key "$PRIVATE_KEY" \
  --rpc-url "$RPC_URL"

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

    SLEEP_TIME=$(( (RANDOM % 11) + 10 ))
    echo "⏳ Sleeping $SLEEP_TIME sec..."
    sleep $SLEEP_TIME
done

echo "✅ All transfers completed!"
