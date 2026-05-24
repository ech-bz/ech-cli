export GITOPS_REPO="${args[--gitops-repo]}"
export GITOPS_PATH="${args[--gitops-path]}"
export SECRET_BACKEND="${args[--secret-backend]}"
export AWS_REGION="${args[--aws-region]}"
export AWS_ACCESS_KEY_ID="${args[--aws-access-key-id]}"
export AWS_SECRET_ACCESS_KEY="${args[--aws-secret-access-key]}"

if [[ "$SECRET_BACKEND" == "aws" ]]; then
  [[ -z "$AWS_REGION" ]] && { echo "--aws-region is required when --secret-backend=aws" >&2; exit 1; }
  [[ -z "$AWS_ACCESS_KEY_ID" ]] && { echo "--aws-access-key-id is required when --secret-backend=aws" >&2; exit 1; }
  [[ -z "$AWS_SECRET_ACCESS_KEY" ]] && { echo "--aws-secret-access-key is required when --secret-backend=aws" >&2; exit 1; }
fi

run_install
