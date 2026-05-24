export K3S_URL="${args[--url]}"
export K3S_TOKEN="${args[--token]}"
export NODE_GROUP="${args[--group]}"

run_join_node
