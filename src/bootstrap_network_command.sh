export NETWORK_NAMESPACE="${args[--namespace]}"
export NETWORK_VALIDATORS="${args[--validators]}"
export NETWORK_EPOCH_DURATION_MS="${args[--epoch-duration-ms]}"
export NETWORK_GENESIS_GAS_AMOUNT="${args[--genesis-gas-amount]}"
export NETWORK_VALIDATOR_STAKE="${args[--validator-stake]}"
export NETWORK_SPONSOR_GAS_OBJECT_COUNT="${args[--sponsor-gas-object-count]}"
export NETWORK_VALIDATOR_P2P_PORT="${args[--validator-p2p-port]}"
export NETWORK_OUTPUT_DIR="${args[--output-dir]}"

run_bootstrap_network
