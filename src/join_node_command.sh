export K3S_URL="${args[--url]}"
export K3S_TOKEN="${args[--token]}"
export NODE_GROUP="${args[--group]-}"
export TAILSCALE_AUTH_KEY="${args[--tailscale-auth-key]}"

run_join_node
