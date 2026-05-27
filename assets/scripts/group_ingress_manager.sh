#!/bin/sh
set -eu

template_path() {
  printf '%s\n' "${GROUP_INGRESS_TEMPLATE_DIR:-/manifests/group_ingress_manager}/$1"
}

render_template() {
  TEMPLATE="$1"
  shift
  env -i PATH="$PATH" "$@" awk '
    function escape_replacement(value) {
      gsub(/\\/, "\\\\", value)
      gsub(/&/, "\\&", value)
      return value
    }

    function sort_keys(n,   i, j, tmp) {
      for (i = 1; i <= n; i++) {
        for (j = i + 1; j <= n; j++) {
          if (length(keys[j]) > length(keys[i]) || (length(keys[j]) == length(keys[i]) && keys[j] < keys[i])) {
            tmp = keys[i]
            keys[i] = keys[j]
            keys[j] = tmp
          }
        }
      }
    }

    BEGIN {
      n = 0
      for (k in ENVIRON) {
        if (k == "PATH") {
          continue
        }
        keys[++n] = k
      }
      sort_keys(n)
    }

    {
      line = $0
      for (i = 1; i <= n; i++) {
        key = keys[i]
        value = escape_replacement(ENVIRON[key])
        gsub("\\$\\{" key "\\}", value, line)
        gsub("\\$" key, value, line)
      }
      print line
    }
  ' "$(template_path "$TEMPLATE")"
}

apply_template() {
  TEMPLATE="$1"
  shift
  render_template "$TEMPLATE" "$@" | kubectl apply -f -
}

is_valid_group() {
  echo "$1" | grep -Eq '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$' && [ "${#1}" -le 63 ]
}

is_valid_domain() {
  echo "$1" | grep -Eq '^([a-z0-9]([a-z0-9-]*[a-z0-9])?)(\.([a-z0-9]([a-z0-9-]*[a-z0-9])?))*$' && [ "${#1}" -le 253 ]
}

stable_hash() {
  printf '%s' "$1" | sha1sum | awk '{print $1}'
}

domain_resource_name() {
  DOMAIN="$1"
  SAFE=$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]' | tr '.:*_' '-----' | tr -cd 'a-z0-9-')
  SAFE=$(printf '%s' "$SAFE" | cut -c1-40)
  HASH=$(stable_hash "$DOMAIN")
  printf 'domain-%s-%s' "$SAFE" "$HASH"
}

route_resource_name() {
  INPUT="$1"
  SAFE=$(printf '%s' "$INPUT" | tr '[:upper:]' '[:lower:]' | tr '/.:*_' '-----' | tr -cd 'a-z0-9-')
  SAFE=$(printf '%s' "$SAFE" | cut -c1-40)
  HASH=$(stable_hash "$INPUT")
  printf 'route-%s-%s' "$SAFE" "$HASH"
}

route_priority() {
  PATH_PREFIX="$1"
  printf '%s' "$((1000 + ${#PATH_PREFIX}))"
}

path_prefix_hash() {
  stable_hash "$1"
}

group_class() {
  printf 'traefik-%s' "$1"
}

ingressgroup_domains() {
  GROUP="$1"
  GROUP_NS="$2"
  kubectl get ingressgroup "$GROUP" -n "$GROUP_NS" -o go-template='{{range .spec.domains}}{{println .}}{{end}}' \
    | awk 'NF>0' \
    | sort -u
}

ingressgroup_routes() {
  GROUP="$1"
  GROUP_NS="$2"
  kubectl get ingressgroup "$GROUP" -n "$GROUP_NS" -o jsonpath='{range .spec.routes[*]}{.pathPrefix}{"|"}{.serviceName}{"|"}{.serviceNamespace}{"|"}{.servicePort}{"\n"}{end}' \
    | awk 'NF>0'
}

node_ip_namespace() {
  GROUP="$1"
  NODE_NAME="$2"
  printf '%s-ip-%s' "$GROUP" "$(stable_hash "$NODE_NAME")"
}

ensure_namespace() {
  NS="$1"
  if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
    kubectl create namespace "$NS"
  fi
}

ensure_ingress_only_taint() {
  NODE_NAME="$1"
  # Block regular workloads on ingress nodes; only pods with explicit toleration may schedule.
  kubectl taint node "$NODE_NAME" ech.bz/ingress-only=true:NoSchedule --overwrite >/dev/null
}

ensure_ip_stack() {
  GROUP="$1"
  GROUP_NS="$2"
  NODE_NAME="$3"
  NODE_IP="$4"
  WATCH_NAMESPACES="$5"
  IP_NS="$(node_ip_namespace "$GROUP" "$NODE_NAME")"
  CLASS="$(group_class "$GROUP")"
  IP_HASH="$(stable_hash "$NODE_NAME")"
  CERT_NAME="node-$(printf '%s' "$NODE_IP" | tr '.' '-' | tr ':' '-')"
  DEFAULT_CERT_SECRET="${CERT_NAME}-tls"

  ensure_namespace "$IP_NS"
  apply_template ip_stack.yaml \
    GROUP="$GROUP" GROUP_NS="$GROUP_NS" IP_NS="$IP_NS" NODE_NAME="$NODE_NAME" NODE_IP="$NODE_IP" CLASS="$CLASS" IP_HASH="$IP_HASH" DEFAULT_CERT_SECRET="$DEFAULT_CERT_SECRET" WATCH_NAMESPACES="$WATCH_NAMESPACES"
}

route_watch_namespaces() {
  GROUP_NS="$1"
  IP_NS="$2"
  PATH_ROUTES_FILE="$3"

  WATCH_FILE="$(mktemp)"
  printf '%s\n%s\n' "$GROUP_NS" "$IP_NS" > "$WATCH_FILE"

  while IFS='|' read -r _ _ SERVICE_NAMESPACE _; do
    if [ -z "$SERVICE_NAMESPACE" ] || [ "$SERVICE_NAMESPACE" = "<no value>" ]; then
      SERVICE_NAMESPACE="$GROUP_NS"
    fi
    if is_valid_group "$SERVICE_NAMESPACE"; then
      printf '%s\n' "$SERVICE_NAMESPACE" >> "$WATCH_FILE"
    fi
  done < "$PATH_ROUTES_FILE"

  sort -u "$WATCH_FILE" | awk 'NR==1{printf "%s", $0; next} {printf ",%s", $0} END{print ""}'
  rm -f "$WATCH_FILE"
}

sync_domain_plane() {
  GROUP="$1"
  GROUP_NS="$2"
  CLASS="$(group_class "$GROUP")"

  DOMAINS_FILE=$(mktemp)
  PATH_ROUTES_FILE=$(mktemp)
  ROUTE_NAMES_FILE=$(mktemp)
  trap 'rm -f "$DOMAINS_FILE" "$PATH_ROUTES_FILE" "$ROUTE_NAMES_FILE"' EXIT

  ingressgroup_domains "$GROUP" "$GROUP_NS" > "$DOMAINS_FILE"
  ingressgroup_routes "$GROUP" "$GROUP_NS" > "$PATH_ROUTES_FILE"

  ISSUER_NAME="$GROUP"
  if ! kubectl get clusterissuer "$ISSUER_NAME" >/dev/null 2>&1; then
    echo "Skipping $GROUP_NS/$GROUP: no ClusterIssuer named $ISSUER_NAME found" >&2
    return 0
  fi

  while read -r DOMAIN; do
    [ -z "$DOMAIN" ] && continue
    if ! is_valid_domain "$DOMAIN"; then
      echo "Skipping invalid domain in $GROUP: $DOMAIN" >&2
      continue
    fi

    DOMAIN_NAME="$(domain_resource_name "$DOMAIN")"
    DOMAIN_SECRET="${DOMAIN_NAME}-tls"
    apply_template dns_certificate.yaml \
      GROUP="$GROUP" GROUP_NS="$GROUP_NS" DOMAIN="$DOMAIN" DOMAIN_NAME="$DOMAIN_NAME" DOMAIN_SECRET="$DOMAIN_SECRET" ISSUER_NAME="$ISSUER_NAME" ISSUER_KIND="ClusterIssuer"
  done < "$DOMAINS_FILE"

  while IFS='|' read -r PATH_PREFIX SERVICE_NAME SERVICE_NAMESPACE SERVICE_PORT; do
    [ -z "$PATH_PREFIX" ] && continue
    if ! printf '%s' "$PATH_PREFIX" | grep -Eq '^/'; then
      echo "Skipping invalid pathPrefix in $GROUP: $PATH_PREFIX" >&2
      continue
    fi
    if [ -z "$SERVICE_NAMESPACE" ] || [ "$SERVICE_NAMESPACE" = "<no value>" ]; then
      SERVICE_NAMESPACE="$GROUP_NS"
    fi
    if ! is_valid_group "$SERVICE_NAMESPACE"; then
      echo "Skipping invalid serviceNamespace in $GROUP: $SERVICE_NAMESPACE" >&2
      continue
    fi
    case "$SERVICE_PORT" in
      ''|*[!0-9]*)
        echo "Skipping invalid servicePort in $GROUP: $SERVICE_PORT" >&2
        continue
        ;;
    esac

    ROUTE_PRIORITY="$(route_priority "$PATH_PREFIX")"
    PATH_PREFIX_HASH="$(path_prefix_hash "$PATH_PREFIX")"

    while read -r DOMAIN; do
      [ -z "$DOMAIN" ] && continue
      DOMAIN_NAME="$(domain_resource_name "$DOMAIN")"
      DOMAIN_SECRET="${DOMAIN_NAME}-tls"
      ROUTE_NAME="$(route_resource_name "$GROUP|$DOMAIN|$PATH_PREFIX|$SERVICE_NAMESPACE|$SERVICE_NAME|$SERVICE_PORT")"
      printf '%s\n' "$ROUTE_NAME" >> "$ROUTE_NAMES_FILE"
      apply_template dns_route.yaml \
        GROUP="$GROUP" GROUP_NS="$GROUP_NS" CLASS="$CLASS" DOMAIN="$DOMAIN" DOMAIN_SECRET="$DOMAIN_SECRET" PATH_PREFIX="$PATH_PREFIX" PATH_PREFIX_HASH="$PATH_PREFIX_HASH" SERVICE_NAME="$SERVICE_NAME" SERVICE_NAMESPACE="$SERVICE_NAMESPACE" SERVICE_PORT="$SERVICE_PORT" ROUTE_NAME="$ROUTE_NAME" ROUTE_PRIORITY="$ROUTE_PRIORITY"
    done < "$DOMAINS_FILE"
  done < "$PATH_ROUTES_FILE"

  sort -u "$ROUTE_NAMES_FILE" -o "$ROUTE_NAMES_FILE"

  for ROUTE in $(kubectl get ingressroute -n "$GROUP_NS" -l ech.bz/managed-by=group-ingress-manager,ech.bz/route-kind=dns-path -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    if ! grep -qFx "$ROUTE" "$ROUTE_NAMES_FILE"; then
      kubectl delete ingressroute "$ROUTE" -n "$GROUP_NS" --ignore-not-found
    fi
  done
}

sync_ip_plane() {
  GROUP="$1"
  GROUP_NS="$2"
  CLASS="$(group_class "$GROUP")"

  NODES_FILE=$(mktemp)
  PATH_ROUTES_FILE=$(mktemp)
  ROUTE_NAMES_FILE=$(mktemp)
  IP_NAMESPACES_FILE=$(mktemp)
  trap 'rm -f "$NODES_FILE" "$PATH_ROUTES_FILE" "$ROUTE_NAMES_FILE" "$IP_NAMESPACES_FILE"' EXIT

  kubectl get nodes -l ech.bz/ingress-group="$GROUP" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"|"}{range .status.addresses[?(@.type=="ExternalIP")]}{.address}{end}{"\n"}{end}' \
    | awk -F'|' '$2=="True" && $3!="" {print $1 "|" $3}' \
    | sort -u > "$NODES_FILE"

  ingressgroup_routes "$GROUP" "$GROUP_NS" > "$PATH_ROUTES_FILE"

  ISSUER_NAME="$GROUP"
  if ! kubectl get clusterissuer "$ISSUER_NAME" >/dev/null 2>&1; then
    echo "Skipping $GROUP_NS/$GROUP IP plane: no ClusterIssuer named $ISSUER_NAME found" >&2
    return 0
  fi

  while IFS='|' read -r NODE_NAME NODE_IP; do
    [ -z "$NODE_NAME" ] && continue
    ensure_ingress_only_taint "$NODE_NAME"
    IP_NS="$(node_ip_namespace "$GROUP" "$NODE_NAME")"
    WATCH_NAMESPACES="$(route_watch_namespaces "$GROUP_NS" "$IP_NS" "$PATH_ROUTES_FILE")"
    if [ -z "$WATCH_NAMESPACES" ]; then
      WATCH_NAMESPACES="$GROUP_NS,$IP_NS"
    fi
    printf '%s\n' "$IP_NS" >> "$IP_NAMESPACES_FILE"
    CERT_NAME="node-$(printf '%s' "$NODE_IP" | tr '.' '-' | tr ':' '-')"
    DEFAULT_CERT_SECRET="${CERT_NAME}-tls"
    ensure_ip_stack "$GROUP" "$GROUP_NS" "$NODE_NAME" "$NODE_IP" "$WATCH_NAMESPACES"

    apply_template ip_certificate.yaml \
      GROUP="$GROUP" GROUP_NS="$GROUP_NS" IP_NS="$IP_NS" NODE_NAME="$NODE_NAME" NODE_IP="$NODE_IP" CERT_NAME="$CERT_NAME" ISSUER_NAME="$ISSUER_NAME" ISSUER_KIND="ClusterIssuer"

    while IFS='|' read -r PATH_PREFIX SERVICE_NAME SERVICE_NAMESPACE SERVICE_PORT; do
      [ -z "$PATH_PREFIX" ] && continue
      if ! printf '%s' "$PATH_PREFIX" | grep -Eq '^/'; then
        echo "Skipping invalid pathPrefix in $GROUP: $PATH_PREFIX" >&2
        continue
      fi
      if [ -z "$SERVICE_NAMESPACE" ] || [ "$SERVICE_NAMESPACE" = "<no value>" ]; then
        SERVICE_NAMESPACE="$GROUP_NS"
      fi
      if ! is_valid_group "$SERVICE_NAMESPACE"; then
        echo "Skipping invalid serviceNamespace in $GROUP: $SERVICE_NAMESPACE" >&2
        continue
      fi
      case "$SERVICE_PORT" in
        ''|*[!0-9]*)
          echo "Skipping invalid servicePort in $GROUP: $SERVICE_PORT" >&2
          continue
          ;;
      esac

      ROUTE_PRIORITY="$(route_priority "$PATH_PREFIX")"
      PATH_PREFIX_HASH="$(path_prefix_hash "$PATH_PREFIX")"
      ROUTE_NAME="$(route_resource_name "$GROUP|$NODE_NAME|$PATH_PREFIX|$SERVICE_NAMESPACE|$SERVICE_NAME|$SERVICE_PORT")"
      printf '%s\n' "$ROUTE_NAME" >> "$ROUTE_NAMES_FILE"

      apply_template ip_route.yaml \
        GROUP="$GROUP" GROUP_NS="$GROUP_NS" IP_NS="$IP_NS" NODE_NAME="$NODE_NAME" NODE_IP="$NODE_IP" CLASS="$CLASS" PATH_PREFIX="$PATH_PREFIX" PATH_PREFIX_HASH="$PATH_PREFIX_HASH" SERVICE_NAME="$SERVICE_NAME" SERVICE_NAMESPACE="$SERVICE_NAMESPACE" SERVICE_PORT="$SERVICE_PORT" ROUTE_NAME="$ROUTE_NAME" ROUTE_PRIORITY="$ROUTE_PRIORITY"
    done < "$PATH_ROUTES_FILE"

    apply_template ip_tlsstore.yaml GROUP="$GROUP" GROUP_NS="$GROUP_NS" IP_NS="$IP_NS" DEFAULT_CERT_SECRET="$DEFAULT_CERT_SECRET"

    for CERT in $(kubectl get certificate -n "$IP_NS" -l ech.bz/managed-by=group-ingress-manager,ech.bz/cert-kind=node-ip -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
      CERT_IP=$(kubectl get certificate "$CERT" -n "$IP_NS" -o jsonpath='{.spec.ipAddresses[0]}' 2>/dev/null || true)
      if [ -z "$CERT_IP" ] || [ "$CERT_IP" != "$NODE_IP" ]; then
        kubectl delete certificate "$CERT" -n "$IP_NS" --ignore-not-found
      fi
    done

    for ROUTE in $(kubectl get ingressroute -n "$IP_NS" -l ech.bz/managed-by=group-ingress-manager,ech.bz/route-kind=ip-path -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
      if ! grep -qFx "$ROUTE" "$ROUTE_NAMES_FILE"; then
        kubectl delete ingressroute "$ROUTE" -n "$IP_NS" --ignore-not-found
      fi
    done
  done < "$NODES_FILE"

  sort -u "$IP_NAMESPACES_FILE" -o "$IP_NAMESPACES_FILE"

  for IP_NS in $(kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | awk -v prefix="${GROUP}-ip-" '$0 ~ "^" prefix {print $0}'); do
    if ! grep -qFx "$IP_NS" "$IP_NAMESPACES_FILE"; then
      kubectl delete namespace "$IP_NS" --ignore-not-found
    fi
  done
}

kubectl get ingressgroups -A -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.namespace}{"\n"}{end}' \
  | awk 'NF>=2' \
  | while read -r GROUP GROUP_NS; do
      if ! is_valid_group "$GROUP"; then
        echo "Skipping invalid ingress group: $GROUP" >&2
        continue
      fi
      sync_domain_plane "$GROUP" "$GROUP_NS"
      sync_ip_plane "$GROUP" "$GROUP_NS"
    done
