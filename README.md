# ecli

## Install

```bash
curl -fsSLO https://github.com/ech-bz/ech-cli/releases/latest/download/ecli
chmod +x ./ecli
```

## install

```bash
sudo ./ecli install --gitops-repo git@github.com:org/gitops-repo \
  --tailscale-auth-key <tskey-auth-...>
sudo ./ecli install --gitops-repo git@github.com:org/gitops-repo \
  --tailscale-auth-key <tskey-auth-...> \
  --pod-cidr 10.42.0.0/16 \
  --secret-backend aws \
  --aws-region eu-central-1 \
  --aws-access-key-id AKIA... \
  --aws-secret-access-key ...
```

## uninstall

```bash
sudo ./ecli uninstall
```

## join-node

```bash
sudo ./ecli join-node --url https://1.2.3.4:6443 --token <token> \
  --tailscale-auth-key <tskey-auth-...>
sudo ./ecli join-node --url https://1.2.3.4:6443 --token <token> --group echbz \
  --tailscale-auth-key <tskey-auth-...>
```

## bootstrap-network

Run this on the master node or any machine that already has working `kubectl` access to the cluster:

```bash
sudo ./ecli bootstrap-network \
  --namespace echbz \
  --validators 4 \
  --epoch-duration-ms 60000 \
  --genesis-gas-amount 9500000000000000 \
  --validator-stake 1000000000 \
  --sponsor-gas-object-count 256 \
  --validator-p2p-port 2001 \
  --output-dir /path/to/ech-gitops/generated
```

This generates `genesis.blob` and `seed-peers.yaml` in the output directory and creates ESO `PushSecret` resources in the `cluster-secrets` namespace so the validator and relay sponsor secrets are pushed into the configured `backend` store.
