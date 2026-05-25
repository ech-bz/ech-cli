#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/sui-utils.sh"

VALIDATORS="${VALIDATORS:?VALIDATORS is required}"
EPOCH_DURATION_MS="${EPOCH_DURATION_MS:?EPOCH_DURATION_MS is required}"
GENESIS_GAS_AMOUNT="${GENESIS_GAS_AMOUNT:?GENESIS_GAS_AMOUNT is required}"
VALIDATOR_STAKE="${VALIDATOR_STAKE:?VALIDATOR_STAKE is required}"
SPONSOR_GAS_OBJECT_COUNT="${SPONSOR_GAS_OBJECT_COUNT:?SPONSOR_GAS_OBJECT_COUNT is required}"
NAMESPACE="${NAMESPACE:?NAMESPACE is required}"
VALIDATOR_P2P_PORT="${VALIDATOR_P2P_PORT:?VALIDATOR_P2P_PORT is required}"
WORK_DIR="/work"
GENESIS_WORK_DIR="/tmp/genesis-work"
GENESIS_CONFIG_PATH="/tmp/genesis-config.yaml"

init_sui_layout
rm -rf "${SUI_KEYS_DIR:?}"/*
rm -rf "${GENESIS_WORK_DIR}" "${GENESIS_CONFIG_PATH}"
mkdir -p "${GENESIS_WORK_DIR}" "${WORK_DIR}/validators" "${WORK_DIR}"

cat >"${GENESIS_CONFIG_PATH}" <<EOF_GENESIS
---
ssfn_config_info: ~
validator_config_info:
EOF_GENESIS

for ((i = 1; i <= VALIDATORS; i++)); do
  idx=$((i - 1))
  validator_dns="sui-validator-${idx}-0.sui-validator.${NAMESPACE}.svc.cluster.local"

  cat >>"${GENESIS_CONFIG_PATH}" <<EOF_VALIDATOR
  - key_pair: $(generate_keypair_bls12381_b64)
    worker_key_pair: $(strip_scheme_flag_b64 "$(generate_keypair_ed25519_b64)")
    account_key_pair: $(generate_keypair_ed25519_b64)
    network_key_pair: $(strip_scheme_flag_b64 "$(generate_keypair_ed25519_b64)")
    network_address: /dns/${validator_dns}/tcp/2000/https
    p2p_address: /dns/${validator_dns}/udp/${VALIDATOR_P2P_PORT}/https
    p2p_listen_address: "0.0.0.0:${VALIDATOR_P2P_PORT}"
    metrics_address: "0.0.0.0:2002"
    narwhal_metrics_address: /ip4/0.0.0.0/tcp/2003/https
    gas_price: 1
    commission_rate: 200
    narwhal_primary_address: /dns/${validator_dns}/udp/2004/https
    narwhal_worker_address: /dns/${validator_dns}/udp/2005/https
    consensus_address: /dns/${validator_dns}/tcp/2006/https
    stake: ${VALIDATOR_STAKE}
    name: ~
EOF_VALIDATOR
done

cat >>"${GENESIS_CONFIG_PATH}" <<EOF_PARAMETERS
parameters:
  chain_start_timestamp_ms: 0
  protocol_version: 124
  allow_insertion_of_extra_objects: true
  epoch_duration_ms: ${EPOCH_DURATION_MS}
  stake_subsidy_start_epoch: 0
  stake_subsidy_initial_distribution_amount: 1000000000000000
  stake_subsidy_period_length: 10
  stake_subsidy_decrease_rate: 1000
accounts:
EOF_PARAMETERS

sponsor_addr="$(generate_keypair_b64 ed25519)"
sponsor_key_file="${SUI_KEYS_DIR}/${sponsor_addr}.key"
if [[ -z "${sponsor_addr}" || ! -s "${sponsor_key_file}" ]]; then
  echo "failed to generate relay sponsor keypair" >&2
  exit 1
fi
cat "${sponsor_key_file}" > "${WORK_DIR}/sponsor-private-key-base64"

echo "  - address: \"${sponsor_addr}\"" >> "${GENESIS_CONFIG_PATH}"
echo "    gas_amounts:" >> "${GENESIS_CONFIG_PATH}"
for ((j = 0; j < SPONSOR_GAS_OBJECT_COUNT; j++)); do
  echo "      - ${GENESIS_GAS_AMOUNT}" >> "${GENESIS_CONFIG_PATH}"
done

sui genesis --working-dir "$GENESIS_WORK_DIR" --force --from-config "${GENESIS_CONFIG_PATH}"

for ((i = 0; i < VALIDATORS; i++)); do
  cfg="$(ls "${GENESIS_WORK_DIR}/sui-validator-${i}-0."*.yaml 2>/dev/null | head -n1 || true)"
  if [[ -z "$cfg" ]]; then
    echo "validator config not found for index ${i}" >&2
    exit 1
  fi

  sed -i -E "s#^db-path:.*#db-path: /data/validator-db#" "$cfg"
  sed -i -E "s#^\s+db-path: .*consensus_db.*#  db-path: /data/consensus-db#" "$cfg"
  sed -i -E "s#genesis-file-location: .*#genesis-file-location: /config/genesis.blob#" "$cfg"

  cp "$cfg" "${WORK_DIR}/validators/validator-${i}.yaml"
done

cp "${GENESIS_WORK_DIR}/genesis.blob" "${WORK_DIR}/genesis.blob"

if [[ ! -f "${GENESIS_WORK_DIR}/fullnode.yaml" ]]; then
  echo "fullnode template config not found in ${GENESIS_WORK_DIR}" >&2
  exit 1
fi

awk '
  /^  seed-peers:/ { in_block=1 }
  in_block && /^  state-sync:/ { exit }
  in_block { print }
' "${GENESIS_WORK_DIR}/fullnode.yaml" > "${WORK_DIR}/seed-peers.yaml"

if [[ ! -s "${WORK_DIR}/seed-peers.yaml" ]]; then
  echo "failed to extract seed-peers from generated fullnode.yaml" >&2
  exit 1
fi

rm -rf "${GENESIS_WORK_DIR}" "${SUI_KEYS_DIR:?}"/*

echo "=== Genesis generation complete ==="
echo "Outputs in ${WORK_DIR}:"
ls -la "${WORK_DIR}/"
ls -la "${WORK_DIR}/validators/"
