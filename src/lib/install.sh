storage_class_exists() {
  kubectl get storageclass "$1" >/dev/null 2>&1
}

ensure_storage_class() {
  local desired_storage_class
  desired_storage_class="ech-rwo"

  if storage_class_exists "$desired_storage_class"; then
    echo "StorageClass ${desired_storage_class} already exists."
    return
  fi

  echo "Creating StorageClass ${desired_storage_class} backed by local-path..."
  kubectl apply -f "$(ecli_assets_dir)/storage_class_local_path.yaml"

  if ! storage_class_exists "$desired_storage_class"; then
    echo "ERROR: failed to create StorageClass ${desired_storage_class}" >&2
    exit 1
  fi
}

run_install() {
  local pod_cidr
  local tailscale_ipv4
  local k3s_join_url
  local k3s_node_token

  pod_cidr="${POD_CIDR:?POD_CIDR is required}"

  # 1. K3s server with native Tailscale VPN integration
  if systemctl is-active --quiet k3s; then
    echo "K3s is already running, skipping installation..."
  else
    echo "Installing Tailscale..."
    install_tailscale

    echo "Installing K3s server with Tailscale VPN integration..."
    local k3s_exec="server"
    k3s_exec+=" --cluster-cidr=${pod_cidr}"
    k3s_exec+=" --disable=traefik,servicelb"
    k3s_exec+=" --vpn-auth=name=tailscale,joinKey=${TAILSCALE_AUTH_KEY}"
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="${k3s_exec}" sh -

    echo "Waiting for K3s to be ready..."
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    local retries=0
    until kubectl get nodes >/dev/null 2>&1; do
      retries=$((retries + 1))
      if [[ $retries -ge 60 ]]; then
        echo "ERROR: K3s did not become ready within 120 seconds" >&2
        exit 1
      fi
      sleep 2
    done

    echo "Waiting for node to be Ready..."
    kubectl wait --for=condition=Ready node --all --timeout=120s
  fi

  ensure_kubectl_access

  tailscale_ipv4="$(get_tailscale_ip)"
  k3s_join_url="https://${tailscale_ipv4}:6443"
  k3s_node_token="$(cat /var/lib/rancher/k3s/server/node-token)"
  if [[ -z "$k3s_node_token" ]]; then
    echo "ERROR: failed to read K3s node token from /var/lib/rancher/k3s/server/node-token" >&2
    exit 1
  fi

  # 2. Helm
  echo "Installing helm..."
  curl -sfL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

  # 3. Helm repos
  helm repo add --force-update jetstack https://charts.jetstack.io
  helm repo add --force-update fluxcd-community https://fluxcd-community.github.io/helm-charts
  helm repo add --force-update external-secrets https://charts.external-secrets.io
  helm repo update

  # 4. Storage class
  echo "Ensuring provider-agnostic StorageClass contract (ech-rwo) on local-path..."
  ensure_storage_class

  # 5. cert-manager
  echo "Installing cert-manager..."
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --set crds.enabled=true \
    --wait

  # 6. Flux
  echo "Installing Flux..."
  helm upgrade --install flux2 fluxcd-community/flux2 \
    --namespace flux-system --create-namespace \
    --set 'sourceController.container.additionalArgs[0]=--storage-addr=:9090' \
    --wait

  echo "Allowing ech-board manager namespace access to source-controller artifacts..."
  kubectl apply -f "$(ecli_assets_dir)/source_controller_allow_ech_board.yaml"

  # 7. External Secrets Operator + ClusterSecretStore
  echo "Installing External Secrets Operator..."
  helm upgrade --install external-secrets external-secrets/external-secrets \
    --namespace external-secrets --create-namespace \
    --set installCRDs=true \
    --wait

  echo "Creating ClusterSecretStore..."
  kubectl create namespace cluster-secrets --dry-run=client -o yaml | kubectl apply -f -
  case "$SECRET_BACKEND" in
    kubernetes)
      kubectl apply -f "$(ecli_assets_dir)/secret_store_kubernetes.yaml"
      ;;
    aws)
      kubectl -n external-secrets create secret generic aws-credentials \
        --from-literal=access-key="${AWS_ACCESS_KEY_ID}" \
        --from-literal=secret-key="${AWS_SECRET_ACCESS_KEY}" \
        --dry-run=client -o yaml | kubectl apply -f -
      AWS_REGION="${AWS_REGION}" envsubst < "$(ecli_assets_dir)/secret_store_aws.yaml" | kubectl apply -f -
      ;;
    *)
      echo "ERROR: unsupported secret backend: $SECRET_BACKEND" >&2
      exit 1
      ;;
  esac

  # 8. IngressGroup CRD
  echo "Installing IngressGroup CRD..."
  kubectl apply -f "$(ecli_assets_dir)/ingress_group_crd.yaml"

  # 9. Traefik CRDs + shared RBAC
  echo "Installing Traefik CRDs and shared RBAC..."
  kubectl apply -f https://raw.githubusercontent.com/traefik/traefik/v3.4/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml
  kubectl apply -f "$(ecli_assets_dir)/traefik_clusterrole.yaml"

  echo "Installing default ClusterIssuer for ingress group 'cluster'..."
  kubectl apply -f "$(ecli_assets_dir)/cluster_issuer_cluster.yaml"

  # 10. Group ingress manager (Traefik + IP certificates per group)
  echo "Deploying group ingress manager..."
  kubectl create namespace ingress-system --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f "$(ecli_assets_dir)/group_ingress_manager.yaml"
  kubectl -n ingress-system create configmap group-ingress-manifests \
    --from-file="$(ecli_assets_dir)/group_ingress_manager" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n ingress-system create configmap group-ingress-script \
    --from-file=sync.sh="$(ecli_root_dir)/assets/scripts/group_ingress_manager.sh" \
    --dry-run=client -o yaml | kubectl apply -f -

  # 11. GitOps repo
  echo "Configuring Flux to watch $GITOPS_REPO..."
  local gitops_url
  local gitops_host
  local gitops_port
  gitops_url=$(gitops_repo_ssh_url "$GITOPS_REPO")
  gitops_host=$(gitops_repo_ssh_host "$GITOPS_REPO")
  gitops_port=$(gitops_repo_ssh_port "$GITOPS_REPO")
  if kubectl -n flux-system get secret gitops-deploy-key >/dev/null 2>&1; then
    echo "Reusing existing flux-system/gitops-deploy-key"
  else
    local keyfile
    local known_hosts
    keyfile=$(mktemp -u)
    ssh-keygen -t ed25519 -f "$keyfile" -N "" -q
    if [ "$gitops_port" = "22" ]; then
      known_hosts=$(ssh-keyscan "$gitops_host" 2>/dev/null)
    else
      known_hosts=$(ssh-keyscan -p "$gitops_port" "$gitops_host" 2>/dev/null)
    fi
    if [ -z "$known_hosts" ]; then
      echo "ERROR: could not fetch SSH host key for $gitops_host:$gitops_port" >&2
      exit 1
    fi
    kubectl create secret generic gitops-deploy-key -n flux-system \
      --from-file=identity="$keyfile" \
      --from-file=identity.pub="${keyfile}.pub" \
      --from-literal=known_hosts="$known_hosts" \
      --dry-run=client -o yaml | kubectl apply -f -
    echo ""
    echo "=== Add this deploy key to your git repo (read-only) ==="
    cat "${keyfile}.pub"
    echo ""
    rm -f "$keyfile" "${keyfile}.pub"
  fi
  SSH_URL="$gitops_url" GITOPS_PATH="$GITOPS_PATH" envsubst < "$(ecli_assets_dir)/gitops_source.yaml" | kubectl apply -f -

  echo ""
  echo "=== Cluster is ready ==="
  echo "Join example:"
  echo "  sudo ./ecli join-node --url ${k3s_join_url} --token ${k3s_node_token} --tailscale-auth-key ${TAILSCALE_AUTH_KEY}"
}

gitops_repo_ssh_url() {
  REPO="$1"
  case "$REPO" in
    ssh://*)
      printf '%s\n' "$REPO"
      ;;
    *@*:*/*)
      USERHOST=${REPO%%:*}
      PATH=${REPO#*:}
      printf 'ssh://%s/%s\n' "$USERHOST" "$PATH"
      ;;
    *)
      echo "ERROR: --gitops-repo must be an SSH URL, e.g. ssh://git@host/org/repo or git@host:org/repo" >&2
      return 1
      ;;
  esac
}

gitops_repo_ssh_host() {
  REPO="$1"
  case "$REPO" in
    ssh://*)
      REST=${REPO#ssh://}
      AUTH_AND_HOST=${REST%%/*}
      HOSTPORT=${AUTH_AND_HOST#*@}
      printf '%s\n' "${HOSTPORT%:*}"
      ;;
    *@*:*/*)
      AFTER_AT=${REPO#*@}
      printf '%s\n' "${AFTER_AT%%:*}"
      ;;
    *)
      echo "ERROR: --gitops-repo must be an SSH URL, e.g. ssh://git@host/org/repo or git@host:org/repo" >&2
      return 1
      ;;
  esac
}

gitops_repo_ssh_port() {
  REPO="$1"
  case "$REPO" in
    ssh://*)
      REST=${REPO#ssh://}
      AUTH_AND_HOST=${REST%%/*}
      HOSTPORT=${AUTH_AND_HOST#*@}
      case "$HOSTPORT" in
        *:*)
          printf '%s\n' "${HOSTPORT##*:}"
          ;;
        *)
          printf '22\n'
          ;;
      esac
      ;;
    *@*:*/*)
      printf '22\n'
      ;;
    *)
      echo "ERROR: --gitops-repo must be an SSH URL, e.g. ssh://git@host/org/repo or git@host:org/repo" >&2
      return 1
      ;;
  esac
}
