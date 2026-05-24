run_join_node() {
  K3S_ARGS=""
  NAME_PREFIX="worker"

  if [[ -n "$NODE_GROUP" ]]; then
    if ! [[ "$NODE_GROUP" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || [[ ${#NODE_GROUP} -gt 63 ]]; then
      echo "ERROR: --group must be a valid DNS-1123 label (lowercase letters, digits, '-') and <= 63 chars" >&2
      exit 1
    fi

    echo "Obtaining public IP..."
    IP=$(curl -s https://checkip.amazonaws.com/)
    K3S_ARGS="--node-external-ip=${IP} --node-label=ech.bz/ingress-group=${NODE_GROUP}"
    NAME_PREFIX="${NODE_GROUP}"
  fi

  echo "Joining cluster..."
  curl -sfL https://get.k3s.io | \
    K3S_URL="$K3S_URL" \
    K3S_TOKEN="$K3S_TOKEN" \
    K3S_NODE_NAME="${NAME_PREFIX}-$(hostname)" \
    INSTALL_K3S_EXEC="agent ${K3S_ARGS}" \
    sh -

  echo "Node joined successfully"
}
