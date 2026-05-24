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
