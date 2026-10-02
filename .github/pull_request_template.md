## What and why

<!-- One or two sentences: what this change does and why it is needed. -->

## Type

- [ ] Feature (`feature/...`)
- [ ] Fix (`fix/...`)
- [ ] Infrastructure / Terraform (`infra/...`)
- [ ] Pipeline / docs (`chore/...`, `docs/...`)

## Checks before merging

- [ ] `ci-ok` is green (unit tests, Helm render, image builds)
- [ ] Infrastructure changes: the Terraform plan in the `infra` check was read, nothing unexpected is destroyed
- [ ] No secrets, keys or passwords in the code

## After merging

Merging to `main` deploys to dev automatically, then waits for approval before prod.
