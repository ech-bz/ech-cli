run_join_node() {
  K3S_ARGS=""
  NAME_PREFIX="worker"
  NODE_NAME=""
  PUBLIC_IPV4=""

  if [[ -n "$NODE_GROUP" ]]; then
    validate_dns1123_label "$NODE_GROUP" "--group"
    NAME_PREFIX="${NODE_GROUP}"
  fi

  NODE_NAME="${NAME_PREFIX}-$(hostname)"

  install_tailscale

  K3S_ARGS="--vpn-auth=name=tailscale,joinKey=${TAILSCALE_AUTH_KEY}"

  if [[ -n "$NODE_GROUP" ]]; then
    PUBLIC_IPV4="$(get_public_ip)"
    K3S_ARGS="${K3S_ARGS} --node-label=ech.bz/ingress-group=${NODE_GROUP} --node-label=ech.bz/public-ip=${PUBLIC_IPV4}"
  fi

  echo "Joining cluster..."
  curl -sfL https://get.k3s.io | \
    K3S_URL="$K3S_URL" \
    K3S_TOKEN="$K3S_TOKEN" \
    K3S_NODE_NAME="${NODE_NAME}" \
    INSTALL_K3S_EXEC="agent ${K3S_ARGS}" \
    sh -

  echo "Node joined successfully"
}
