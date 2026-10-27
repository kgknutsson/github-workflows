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
In CI the guard reads that variable through the GitHub API with `GITHUB_TOKEN`. If the variable is missing, empty, or unreadable, the job fails. Fix the variable or job permissions (`actions: read`) and re-run the workflow.
