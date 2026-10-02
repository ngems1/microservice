# Git strategy: GitHub Flow

One rule: **`main` is always deployable**. Nobody pushes to it directly. Every change goes through a short-lived branch and a pull request (PR), and merging is what deploys it.

```
main ──●───────────────●──────────────●──►   every merge = deploy dev (+ prod after approval)
        \             /  \            /
         feature/x ──●    fix/y ─────●       short branches, one PR each
              PR: ci-ok + terraform plan
```

## Branch names

| Prefix | For | Example |
|---|---|---|
| `feature/` | New behavior | `feature/checkout-order-events` |
| `fix/` | Bug fix | `fix/inventory-double-reserve` |
| `infra/` | Terraform | `infra/rds-backup-window` |
| `chore/`, `docs/` | Pipelines, docs | `docs/runbook` |

Keep branches small and short (hours or a day, not weeks). That keeps merges easy.

## What runs where

| Event | Workflow | What happens |
|---|---|---|
| PR opened / updated | `ci` | Unit tests, Helm render (dev + prod), Docker build of the changed services. Result: the `ci-ok` check |
| PR touching `terraform-aws/` | `infra` | `terraform plan` with the **read-only** role, posted in the run's Summary |
| Merge to `main` | `deploy` | Build, scan, deploy dev, approval, deploy prod |
| Merge to `main` touching `terraform-aws/` | `infra` | `terraform apply` with the deploy role |

No AWS credentials ever reach a PR except the read-only plan role.

## Day-to-day (PowerShell, in the project folder)

```powershell
# 1. Start from an up-to-date main
git switch main
git pull

# 2. Create the branch
git switch -c feature/checkout-order-events

# 3. Work, then commit (as often as you like)
git add -A
git commit -m "checkout: publish OrderCreated to EventBridge"

# 4. Push the branch. Git prints a link to open the pull request.
git push -u origin feature/checkout-order-events
```

5. On GitHub, open the **pull request**, fill in the template, and wait for **`ci-ok`** to turn green. If it's red, fix the code, commit and push again; the checks re-run by themselves.
6. Click **Squash and merge**. The branch is deleted automatically.
7. Watch **Actions > deploy**: dev deploys, then approve prod.
8. Back on your laptop:

```powershell
git switch main
git pull
git branch -D feature/checkout-order-events
```

## One-time GitHub settings

### A. Merge options

**Settings > General > Pull Requests**:

- Tick **Allow squash merging**. Untick merge commits and rebase merging. Each PR becomes one clean commit on `main`.
- Tick **Automatically delete head branches**.

### B. Protect `main` (ruleset)

**Settings > Rules > Rulesets > New ruleset > New branch ruleset**:

| Setting | Value |
|---|---|
| Ruleset name | `main` |
| Enforcement status | **Active** |
| Target branches | **Add target > Include default branch** |
| Restrict deletions | On |
| Block force pushes | On |
| Require linear history | On |
| Require a pull request before merging | On. Required approvals: **0** while you work alone (GitHub doesn't let you approve your own PR). Raise it to 1 when a teammate joins. Tick "Require conversation resolution". |
| Require status checks to pass | On. Add **`ci-ok`**. Later, once AWS is connected, also add **`terraform`** (the infra plan). Tick "Require branches to be up to date". |

Click **Create**.

The `ci-ok` check appears in the list only after it has run once, so open your first PR before this step, or come back and add it.

**Private repository on a free plan?** Rulesets are only enforced on public repos, or private repos on GitHub Pro/Team. Either make the repo public (it holds no secrets: AWS access is through OIDC roles) or follow the same flow by discipline.

## Why GitHub Flow here

- **One long-lived branch** (`main`), so there's no `develop` or `release` branch to keep in sync. Environments are handled by the pipeline (dev, then prod after approval), not by branches.
- **Fast feedback:** every PR is tested and built before it can merge.
- **Safe deploys:** prod only gets images that passed in dev. A rollback is a re-run of `deploy` with an older commit SHA.
