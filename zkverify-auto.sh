#!/bin/bash

set -e

# Hỏi API key từ người dùng
read -p "🔐 Enter your API key: " API_KEY
read -p "🔢 How many submissions to generate? " N

if [[ -z "$API_KEY" || -z "$N" ]]; then
  echo "❌ Missing API key or submission count!"
  exit 1
fi

# ========== STEP 1: ENV SETUP ==========
echo "✅ Installing dependencies..."
sudo apt update && sudo apt install -y curl git jq
npm install -g snarkjs circom
npm install circomlib

# ========== STEP 2: COMPILE CIRCUIT ==========
echo "✅ Compiling circuit..."
mkdir -p circuits/sum_greater_than_js keys proofs input witness scripts

cat > circuits/sum_greater_than.circom <<EOF
pragma circom 2.0.0;
include "../node_modules/circomlib/circuits/comparators.circom";

template SumGreaterThan() {
    signal input a;
    signal input b;
    signal output is_greater;

    signal sum;
    sum <== a + b;

    component gt = GreaterThan(16);
    gt.in[0] <== sum;
    gt.in[1] <== 10;
    is_greater <== gt.out;
}

component main = SumGreaterThan();
EOF

circom circuits/sum_greater_than.circom --r1cs --wasm --sym -o circuits/

# ========== STEP 3: PTAU & ZKEY ==========
echo "✅ Preparing powers of tau and zkey..."
snarkjs powersoftau new bn128 12 pot12_0000.ptau -v
snarkjs powersoftau contribute pot12_0000.ptau pot12_0001.ptau --name="zkverify" -v -e="zkverify-challenge"
snarkjs powersoftau prepare phase2 pot12_0001.ptau pot12_final.ptau

snarkjs groth16 setup circuits/sum_greater_than.r1cs pot12_final.ptau keys/sum_greater_than.zkey
snarkjs zkey export verificationkey keys/sum_greater_than.zkey keys/verification_key.json

# ========== STEP 4: CREATE generatePayload.js ==========
echo "✅ Creating generatePayload.js..."

cat > scripts/generatePayload.js <<'EOF'
const fs = require("fs");

const proof = JSON.parse(fs.readFileSync("proofs/proof.json", "utf8"));
const publicSignals = JSON.parse(fs.readFileSync("proofs/public.json", "utf8"));
const vk = JSON.parse(fs.readFileSync("keys/verification_key.json", "utf8"));

const payload = {
  proofType: "groth16",
  vkRegistered: false,
  proofOptions: {
    library: "snarkjs",
    curve: "bn128"
  },
  proofData: {
    proof: {
      pi_a: proof.pi_a.map(String),
      pi_b: proof.pi_b.map(pair => pair.map(String)),
      pi_c: proof.pi_c.map(String)
    },
    publicSignals: publicSignals.map(String),
    vk
  }
};

fs.writeFileSync("payload.json", JSON.stringify(payload, null, 2));
EOF

# ========== STEP 5–7: LOOP PROOFS ==========
echo "✅ Starting loop to create and submit payloads..."

> submit.log

for i in $(seq 1 $N); do
  echo "🔁 [$i/$N] Generating input..."
  A=$(( RANDOM % 20 + 1 ))
  B=$(( RANDOM % 20 + 1 ))
  echo "{ \"a\": $A, \"b\": $B }" > input/input.json

  snarkjs wtns calculate circuits/sum_greater_than_js/sum_greater_than.wasm input/input.json witness/witness.wtns
  snarkjs groth16 prove keys/sum_greater_than.zkey witness/witness.wtns proofs/proof.json proofs/public.json

  node scripts/generatePayload.js

  SUCCESS=false
  ATTEMPT=1

  while [ $SUCCESS = false ] && [ $ATTEMPT -le 5 ]; do
    echo "🚀 Submitting payload #$i (Attempt $ATTEMPT)..."
    RESPONSE=$(curl -s -X POST https://relayer-api.horizenlabs.io/api/v1/submit-proof/$API_KEY \
      -H "Content-Type: application/json" \
      -d @payload.json)

    echo "[$i][$ATTEMPT] $RESPONSE" | tee -a submit.log

    if [[ $RESPONSE == *"Too Many Requests"* ]]; then
      echo "⏳ Too Many Requests. Waiting before retry..."
      RETRY_DELAY=$(( RANDOM % 101 + 100 )) # Wait 100-200s
      echo "⏳ Waiting $RETRY_DELAY seconds before retry..."
      sleep $RETRY_DELAY
      ((ATTEMPT++))
    else
      SUCCESS=true
    fi
  done

  DELAY=$(( RANDOM % 181 + 120 )) # Chờ ngẫu nhiên từ 120 đến 300 giây (2–5 phút)
  echo "⏳ Waiting $DELAY seconds before next submission... "
  sleep $DELAY
done

echo "🎉 Done. All results saved in submit.log"
