#!/usr/bin/env bash
set -euo pipefail

SUI_TOOLS_IMAGE="${SUI_TOOLS_IMAGE:-docker.io/mysten/sui-tools:b2f82f7091e3e3a827aee57eba95bc6b044a7c26}"
CLUSTER_SECRETS_NAMESPACE="${CLUSTER_SECRETS_NAMESPACE:-cluster-secrets}"
GENESIS_RUNNER_IDLE_IMAGE="${GENESIS_RUNNER_IDLE_IMAGE:-alpine:3.20}"

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 1
  fi
}

validate_positive_int() {
  local value="$1"
  local label="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -le 0 ]]; then
    echo "ERROR: $label must be a positive integer" >&2
    exit 1
  fi
}

publish_push_secret() {
  local source_secret_name="$1"
  local destination_secret_name="$2"
  local secret_key="$3"
  local property="$4"

  CLUSTER_SECRETS_NAMESPACE="${CLUSTER_SECRETS_NAMESPACE}" \
  SOURCE_SECRET_NAME="${source_secret_name}" \
  DESTINATION_SECRET_NAME="${destination_secret_name}" \
  SECRET_KEY="${secret_key}" \
  PROPERTY="${property}" \
    envsubst < "$(ecli_assets_dir)/push_secret.yaml" | kubectl apply -f -
}

cleanup_runner_resources() {
  local pod_name="$1"
  local cm_name="$2"

  if [[ -n "$pod_name" ]]; then
    kubectl -n "$CLUSTER_SECRETS_NAMESPACE" delete pod "$pod_name" --ignore-not-found >/dev/null 2>&1 || true
  fi

  if [[ -n "$cm_name" ]]; then
    kubectl -n "$CLUSTER_SECRETS_NAMESPACE" delete configmap "$cm_name" --ignore-not-found >/dev/null 2>&1 || true
  fi
}

print_runner_debug() {
  local pod_name="$1"

  echo "=== Genesis runner debug ===" >&2
  kubectl -n "$CLUSTER_SECRETS_NAMESPACE" get pod "$pod_name" -o wide >&2 || true
  kubectl -n "$CLUSTER_SECRETS_NAMESPACE" describe pod "$pod_name" >&2 || true
  kubectl -n "$CLUSTER_SECRETS_NAMESPACE" logs "$pod_name" -c genesis >&2 || true
}

run_bootstrap_network() {
  local namespace
  local validators
  local epoch_duration_ms
  local genesis_gas_amount
  local validator_stake
  local sponsor_gas_object_count
  local validator_p2p_port
  local output_dir
  local work_dir
  local validator_count
  local validator_file
  local basename
  local index
  local sponsor_file
  local runner_pod
  local runner_cm
  local run_id
  local validators_published
  local source_secret_name
  local destination_secret_name

  namespace="${NETWORK_NAMESPACE:?NETWORK_NAMESPACE is required}"
  validators="${NETWORK_VALIDATORS:?NETWORK_VALIDATORS is required}"
  epoch_duration_ms="${NETWORK_EPOCH_DURATION_MS:?NETWORK_EPOCH_DURATION_MS is required}"
  genesis_gas_amount="${NETWORK_GENESIS_GAS_AMOUNT:?NETWORK_GENESIS_GAS_AMOUNT is required}"
  validator_stake="${NETWORK_VALIDATOR_STAKE:?NETWORK_VALIDATOR_STAKE is required}"
  sponsor_gas_object_count="${NETWORK_SPONSOR_GAS_OBJECT_COUNT:?NETWORK_SPONSOR_GAS_OBJECT_COUNT is required}"
  validator_p2p_port="${NETWORK_VALIDATOR_P2P_PORT:?NETWORK_VALIDATOR_P2P_PORT is required}"
  output_dir="${NETWORK_OUTPUT_DIR:?NETWORK_OUTPUT_DIR is required}"

  require_command kubectl
  require_command envsubst
  require_command grep
  require_command sort
  require_command wc
  require_command tr
  require_command mktemp

  ensure_kubectl_access

  validate_dns1123_label "$namespace" "namespace"
  validate_dns1123_label "$CLUSTER_SECRETS_NAMESPACE" "cluster secrets namespace"
  validate_positive_int "$validators" "validators"
  validate_positive_int "$epoch_duration_ms" "epoch duration"
  validate_positive_int "$genesis_gas_amount" "genesis gas amount"
  validate_positive_int "$validator_stake" "validator stake"
  validate_positive_int "$sponsor_gas_object_count" "sponsor gas object count"
  validate_positive_int "$validator_p2p_port" "validator P2P port"

  mkdir -p "$output_dir"
  chmod 755 "$output_dir"

  echo "=== Bootstrap network ==="
  echo "  namespace:          ${namespace}"
  echo "  validators:         ${validators}"
  echo "  output-dir:         ${output_dir}"
  echo "  sui-tools image:    ${SUI_TOOLS_IMAGE}"
  echo "  runner namespace:   ${CLUSTER_SECRETS_NAMESPACE}"

  work_dir="$(mktemp -d)"
  run_id="$(printf '%05d%05d' "$RANDOM" "$RANDOM")"
  runner_pod="ecli-genesis-${run_id}"
  runner_cm="${runner_pod}-scripts"
  trap 'cleanup_runner_resources "${runner_pod:-}" "${runner_cm:-}"; rm -rf "${work_dir:-}"' EXIT

  kubectl create namespace "${CLUSTER_SECRETS_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "${CLUSTER_SECRETS_NAMESPACE}" create configmap "${runner_cm}" \
    --from-file=generate-genesis-network.sh="$(ecli_root_dir)/assets/scripts/generate_genesis_network.sh" \
    --from-file=sui-utils.sh="$(ecli_root_dir)/assets/scripts/sui-utils.sh" \
    --dry-run=client -o yaml | kubectl apply -f -

  RUNNER_POD="${runner_pod}" \
  RUNNER_CM="${runner_cm}" \
  SUI_TOOLS_IMAGE="${SUI_TOOLS_IMAGE}" \
  GENESIS_RUNNER_IDLE_IMAGE="${GENESIS_RUNNER_IDLE_IMAGE}" \
  VALIDATORS="${validators}" \
  EPOCH_DURATION_MS="${epoch_duration_ms}" \
  GENESIS_GAS_AMOUNT="${genesis_gas_amount}" \
  VALIDATOR_STAKE="${validator_stake}" \
  SPONSOR_GAS_OBJECT_COUNT="${sponsor_gas_object_count}" \
  NAMESPACE="${namespace}" \
  VALIDATOR_P2P_PORT="${validator_p2p_port}" \
    envsubst < "$(ecli_assets_dir)/genesis_runner_pod.yaml" | kubectl -n "${CLUSTER_SECRETS_NAMESPACE}" apply -f -

  if ! kubectl -n "${CLUSTER_SECRETS_NAMESPACE}" wait --for=condition=Initialized "pod/${runner_pod}" --timeout=10m >/dev/null; then
    echo "ERROR: genesis init container did not complete successfully" >&2
    print_runner_debug "${runner_pod}"
    exit 1
  fi

  if ! kubectl -n "${CLUSTER_SECRETS_NAMESPACE}" wait --for=condition=Ready "pod/${runner_pod}" --timeout=2m >/dev/null; then
    echo "ERROR: artifacts container did not become ready" >&2
    print_runner_debug "${runner_pod}"
    exit 1
  fi

  mkdir -p "${work_dir}/validators"
  kubectl -n "${CLUSTER_SECRETS_NAMESPACE}" cp "${runner_pod}:/work/genesis.blob" "${work_dir}/genesis.blob" -c artifacts
  kubectl -n "${CLUSTER_SECRETS_NAMESPACE}" cp "${runner_pod}:/work/seed-peers.yaml" "${work_dir}/seed-peers.yaml" -c artifacts
  kubectl -n "${CLUSTER_SECRETS_NAMESPACE}" cp "${runner_pod}:/work/sponsor-private-key-base64" "${work_dir}/sponsor-private-key-base64" -c artifacts
  kubectl -n "${CLUSTER_SECRETS_NAMESPACE}" cp "${runner_pod}:/work/validators/." "${work_dir}/validators/" -c artifacts

  if [[ ! -s "${work_dir}/genesis.blob" ]]; then
    echo "ERROR: genesis.blob missing or empty after in-cluster generation" >&2
    exit 1
  fi

  if [[ ! -s "${work_dir}/seed-peers.yaml" ]]; then
    echo "ERROR: seed-peers.yaml missing or empty after in-cluster generation" >&2
    exit 1
  fi

  if [[ ! -s "${work_dir}/sponsor-private-key-base64" ]]; then
    echo "ERROR: sponsor key missing or empty after in-cluster generation" >&2
    exit 1
  fi

  cp "${work_dir}/genesis.blob" "${output_dir}/genesis.blob"
  cp "${work_dir}/seed-peers.yaml" "${output_dir}/seed-peers.yaml"
  chmod 644 "${output_dir}/genesis.blob" "${output_dir}/seed-peers.yaml"

  validator_count="$(grep -o 'sui-validator-[0-9]\+-0\.sui-validator' "${output_dir}/seed-peers.yaml" | sort -u | wc -l | tr -d ' ')"
  validate_positive_int "$validator_count" "derived validator count"
  if [[ "$validator_count" -ne "$validators" ]]; then
    echo "ERROR: derived validator count (${validator_count}) does not match requested validators (${validators})" >&2
    exit 1
  fi

  echo "Publishing secrets into ${CLUSTER_SECRETS_NAMESPACE} via ESO PushSecret..."
  validators_published=0
  for validator_file in "${work_dir}"/validators/validator-*.yaml; do
    [[ -f "${validator_file}" ]] || continue
    basename="$(basename "${validator_file}")"
    index="${basename#validator-}"
    index="${index%.yaml}"
    source_secret_name="${namespace}-validator-${index}-src"
    destination_secret_name="${namespace}-validator-${index}"
    kubectl -n "${CLUSTER_SECRETS_NAMESPACE}" create secret generic "${source_secret_name}" \
      --from-file=validator.yaml="${validator_file}" \
      --dry-run=client -o yaml | kubectl apply -f -
    publish_push_secret "${source_secret_name}" "${destination_secret_name}" validator.yaml validator.yaml
    echo "  published ${destination_secret_name} via PushSecret"
    validators_published=$((validators_published + 1))
  done

  if [[ "$validators_published" -ne "$validators" ]]; then
    echo "ERROR: published validator secrets (${validators_published}) does not match requested validators (${validators})" >&2
    exit 1
  fi

  sponsor_file="${work_dir}/sponsor-private-key-base64"
  if [[ ! -f "${sponsor_file}" ]]; then
    echo "ERROR: sponsor key not found: ${sponsor_file}" >&2
    exit 1
  fi

  source_secret_name="${namespace}-relay-sponsor-src"
  destination_secret_name="${namespace}-relay-sponsor"
  kubectl -n "${CLUSTER_SECRETS_NAMESPACE}" create secret generic "${source_secret_name}" \
    --from-file=private_key_base64="${sponsor_file}" \
    --dry-run=client -o yaml | kubectl apply -f -
  publish_push_secret "${source_secret_name}" "${destination_secret_name}" private_key_base64 private_key_base64
  echo "  published ${destination_secret_name} via PushSecret"

  cleanup_runner_resources "$runner_pod" "$runner_cm"
  runner_pod=""
  runner_cm=""
  trap - EXIT

  echo ""
  echo "=== Network bootstrap complete ==="
  echo "Genesis artifacts written to: ${output_dir}"
  echo "Source secrets and PushSecrets created in namespace: ${CLUSTER_SECRETS_NAMESPACE}"
  echo "Next step: commit genesis.blob and seed-peers.yaml into your gitops repo."
}
