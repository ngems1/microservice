# terraform-bootstrap

Creates what GitHub Actions needs before it can run `terraform-aws`:

| Resource | Why |
|---|---|
| S3 bucket `week3-tfstate-<account-id>` | Holds every Terraform state (private, encrypted, versioned, HTTPS only, protected against `destroy`) |
| Role `week3-gha-plan` | Read-only, for pull-request plans |
| Role `week3-gha-deploy` | Applies Terraform and deploys, only from `main` or the `dev` / `prod` environments |
| GitHub OIDC provider | Only when `create_oidc_provider = true`. The normal setup creates it by hand. |

## Normal way: the bootstrap workflow

Follow **docs/week3/BOOTSTRAP.md**. `.github/workflows/bootstrap.yml` runs this folder for you:

- It plans first, and applies only when you tick "apply".
- It adopts resources that already exist (`import-existing.sh`).
- It stores this folder's own state in the bucket under `bootstrap/terraform.tfstate`.

## Alternative: AWS CloudShell

If you can't use the workflow, run it once in CloudShell (us-east-1), which is already logged in as you:

```bash
TF_VERSION=1.12.2
mkdir -p ~/bin
curl -sSLo /tmp/tf.zip https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip
unzip -o /tmp/tf.zip -d ~/bin && rm /tmp/tf.zip && export PATH="$HOME/bin:$PATH"

# upload a zip of this folder (Actions > Upload file), then:
unzip terraform-bootstrap.zip && cd terraform-bootstrap
terraform init
terraform apply -var github_owner=<your-github-user> -var github_repo=<your-repo>
```

If the GitHub OIDC provider already exists in the account, add `-var create_oidc_provider=false`.

## Removing it

The bucket is protected by `prevent_destroy`. Destroy `terraform-aws` first, then remove the `prevent_destroy` block and run `terraform destroy` here.
