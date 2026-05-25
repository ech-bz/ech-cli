run_join_node() {
  K3S_ARGS=""
  NAME_PREFIX="worker"

  if [[ -n "$NODE_GROUP" ]]; then
    validate_dns1123_label "$NODE_GROUP" "--group"

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
