run_uninstall() {
  ensure_kubectl_access

  echo "Removing GitOps wiring..."
  kubectl delete -f "$(ecli_assets_dir)/gitops_source.yaml" --ignore-not-found

  echo "Removing ingress reconciler..."
  kubectl delete -f "$(ecli_assets_dir)/group_ingress_manager.yaml" --ignore-not-found
  kubectl delete -f "$(ecli_assets_dir)/traefik_clusterrole.yaml" --ignore-not-found

  echo "Removing managed IP-plane namespaces..."
  for GROUP in $(kubectl get ingressgroups -A -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | awk 'NF>0'); do
    kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | awk -v prefix="${GROUP}-ip-" '$0 ~ "^" prefix {print $0}' \
      | while read -r IP_NS; do
          [ -z "$IP_NS" ] && continue
          kubectl delete namespace "$IP_NS" --ignore-not-found
        done
  done

  echo "Removing IngressGroup CRD..."
  kubectl delete -f "$(ecli_assets_dir)/ingress_group_crd.yaml" --ignore-not-found

  echo "Removing Secret backend..."
  kubectl delete -f "$(ecli_assets_dir)/secret_store_kubernetes.yaml" --ignore-not-found
  kubectl delete -f "$(ecli_assets_dir)/secret_store_aws.yaml" --ignore-not-found
  kubectl delete clustersecretstore backend --ignore-not-found

  echo "Removing Helm releases..."
  helm uninstall external-secrets -n external-secrets --wait 2>/dev/null || true
  helm uninstall flux2 -n flux-system --wait 2>/dev/null || true
  helm uninstall cert-manager -n cert-manager --wait 2>/dev/null || true

  echo "Removing namespaces..."
  kubectl delete namespace ingress-system cluster-secrets external-secrets flux-system cert-manager --ignore-not-found

  echo ""
  echo "=== Cluster add-ons removed ==="
}
