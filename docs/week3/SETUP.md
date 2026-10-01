# Week 3 setup: from zero to an EKS cluster

No local tools needed except GitHub Desktop and a browser. Terraform, Docker, kubectl and Helm all run inside GitHub Actions or AWS CloudShell.

## 1. Workflows

`.github/workflows/` must contain only our workflows: `bootstrap.yml` and `infra.yml`.

## 2. Put the folder on GitHub

1. Install GitHub Desktop (desktop.github.com) and sign in.
2. File > Add local repository > choose the `project-3` folder > click "create a repository" > name it (for example `week3-boutique`) > Create repository.
3. Click **Publish repository**. Private is fine.

The first push may start the `infra` workflow. It fails because AWS is not connected yet. That is expected.

## 3. Connect GitHub to AWS

Follow **[BOOTSTRAP.md](BOOTSTRAP.md)**: about 15 minutes of console clicks, then the `bootstrap` workflow creates the state bucket and the two pipeline roles.

## 4. Check the GitHub variables

**Settings > Secrets and variables > Actions > Variables** must now contain:

- **Repository variables:** `AWS_REGION`, `AWS_PLAN_ROLE_ARN`, `AWS_DEPLOY_ROLE_ARN`, `TF_STATE_BUCKET`, `ADMIN_PRINCIPAL_ARN`
- **On the `prod` environment:** `AWS_BOOTSTRAP_ROLE_ARN`

## 5. Create the infrastructure

Actions tab > **infra** > Run workflow > action = `apply`. It takes about 25 to 35 minutes (EKS and the Multi-AZ prod database are the slow parts). It creates the shared VPC, EKS cluster and ECR repos, plus a full set of data stores, queues, Lambda and IAM roles for **dev** and for **prod**.

## 6. Look at the cluster (optional, from CloudShell)

```bash
aws eks update-kubeconfig --name week3-boutique-eks --region us-east-1
curl -sLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && chmod +x kubectl && mkdir -p ~/bin && mv kubectl ~/bin/
kubectl get nodes
```

If you get "Unauthorized", your IAM identity was not set in `ADMIN_PRINCIPAL_ARN` (step 4).

## Tear down (do this at the end of every day)

Actions > infra > Run workflow > action = `destroy`. The running cost is roughly 9 to 12 USD per day (EKS control plane, 3 nodes, NAT gateway, 2 MySQL databases, 2 Redis nodes, logs).
