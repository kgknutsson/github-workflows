# github-workflows
Reusable GitHub Workflows

## terraform-java-app-service.yml

Optional input `manage_deploy_slot_lifecycle` (default `false`): when `true` with `explicit_slot_swap`, starts the deploy `slot-name` before package deploy and stops it after production health checks pass, to free App Service plan memory between releases.

## Public content

Do not add organization names, product names, host names, tenant ids, or subscription ids to files.
Pass a caller-specific runner label from the caller repository.
A guard workflow scans each push.

Set repository variable `PUBLIC_REPO_DENYLIST` under **Settings → Secrets and variables → Actions → Variables**.
Use one term per line. Repo admins can view and edit this variable.
For local commits, set `DENYLIST_FILE` to a path outside the repository and run `.githooks/pre-commit`.
The guard tries the repository variable through the GitHub API when the token can read it. If the lookup fails, it uses the masked repository secret `PUBLIC_REPO_DENYLIST`. The Actions token often cannot read variables; keep the secret aligned with the variable after edits.

When you change the repository variable, refresh the masked secret from a clone of this repository:

`gh secret set PUBLIC_REPO_DENYLIST --body "$(gh variable get PUBLIC_REPO_DENYLIST)"`
