#!/bin/bash

set -e

# Ask for API key and number of submissions
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

# ========== STEP 2: COMPILE CIRCUIT ==========
echo "✅ Compiling circuit..."
mkdir -p zkverify/{circuits,keys,proofs,input,witness,scripts}
cd zkverify

cat > circuits/add_and_multiply.circom <<EOF
template QuizSimple() {
    signal input a;
    signal input b;
    signal input result;

    result === (a + b + 5);
}

component main = QuizSimple();
EOF

circom circuits/add_and_multiply.circom --r1cs --wasm --sym -o circuits/
mv add_and_multiply.* circuits/

# ========== STEP 3: PTAU & ZKEY ==========
echo "✅ Preparing powers of tau and zkey..."
snarkjs powersoftau new bn128 12 keys/pot12_0000.ptau -v
snarkjs powersoftau contribute keys/pot12_0000.ptau keys/pot12_final.ptau --name="zkverify" -v -e="zkverify-challenge"
snarkjs powersoftau prepare phase2 keys/pot12_final.ptau keys/pot12_final_prepared.ptau

snarkjs groth16 setup circuits/add_and_multiply.r1cs keys/pot12_final_prepared.ptau keys/add_and_multiply_0000.zkey
snarkjs zkey contribute keys/add_and_multiply_0000.zkey keys/add_and_multiply_final.zkey --name="zkverify" -v -e="zkverify-contrib"
snarkjs zkey export verificationkey keys/add_and_multiply_final.zkey keys/verification_key.json

# ========== STEP 4: CREATE generatePayload.js ==========
echo "✅ Creating generatePayload.js..."

cat > scripts/generatePayload.js <<'EOF'
const fs = require("fs");

const proof = JSON.parse(fs.readFileSync("proofs/proof.json", "utf8"));
const publicSignals = JSON.parse(fs.readFileSync("proofs/public.json", "utf8"));
const vk = JSON.parse(fs.readFileSync("keys/verification_key.json", "utf8"));

const payload = {
  proofType: "groth16",
  vkRegistered: true,
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
  A=$(( RANDOM % 50 + 1 ))
  B=$(( RANDOM % 50 + 1 ))
  RESULT=$(( A + B + 5 ))
  echo "{ \"a\": $A, \"b\": $B, \"result\": $RESULT }" > input/input.json

  snarkjs wtns calculate circuits/add_and_multiply.wasm input/input.json witness/witness.wtns
  snarkjs groth16 prove keys/add_and_multiply_final.zkey witness/witness.wtns proofs/proof.json proofs/public.json

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

  DELAY=$(( RANDOM % 101 + 100 )) # Wait 100-200s before next submission
  echo "⏳ Waiting $DELAY seconds before next submission... "
  sleep $DELAY
done

echo "🎉 Done. All results saved in submit.log"
