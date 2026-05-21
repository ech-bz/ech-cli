# ecli

## Install

```bash
curl -fsSLO https://github.com/ech-bz/ech-cli/releases/latest/download/ecli
chmod +x ./ecli
```

## install

```bash
sudo ./ecli install --gitops-repo git@github.com:org/gitops-repo
sudo ./ecli install --gitops-repo git@github.com:org/gitops-repo \
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
sudo ./ecli join-node --url https://1.2.3.4:6443 --token <token>
sudo ./ecli join-node --url https://1.2.3.4:6443 --token <token> --group echbz
```
