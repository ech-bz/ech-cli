ecli_root_dir() {
  if [ -n "${ECLI_ROOT_DIR:-}" ]; then
    printf '%s\n' "$ECLI_ROOT_DIR"
    return
  fi

  local script_dir
  script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  printf '%s\n' "$script_dir"
}

ecli_assets_dir() {
  printf '%s\n' "$(ecli_root_dir)/assets/manifests"
}

validate_dns1123_label() {
  local value="$1"
  local label="$2"

  if ! [[ "$value" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || [[ ${#value} -gt 63 ]]; then
    echo "ERROR: $label must be a valid DNS-1123 label (lowercase letters, digits, '-') and <= 63 chars" >&2
    exit 1
  fi
}

ensure_kubectl_access() {
  if [[ -z "${KUBECONFIG:-}" && -f /etc/rancher/k3s/k3s.yaml ]]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  fi

  if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "ERROR: kubectl cannot reach a Kubernetes cluster. Set KUBECONFIG or current context first." >&2
    exit 1
  fi
}

get_public_ip() {
  curl -fsS --max-time 5 https://checkip.amazonaws.com
}

install_tailscale() {
  if command -v tailscale >/dev/null 2>&1 && command -v tailscaled >/dev/null 2>&1; then
    systemctl enable --now tailscaled 2>/dev/null || true
    return
  fi

  echo "Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
  systemctl enable --now tailscaled
}

get_tailscale_ip() {
  local tailscale_ipv4

  tailscale_ipv4="$(tailscale ip -4)"

  if [[ -z "$tailscale_ipv4" || "$tailscale_ipv4" == *$'\n'* ]]; then
    echo "ERROR: tailscale ip -4 must return exactly one IPv4 address" >&2
    printf '%s\n' "$tailscale_ipv4" >&2
    exit 1
  fi

  printf '%s\n' "$tailscale_ipv4"
}
