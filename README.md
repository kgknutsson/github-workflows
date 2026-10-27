# github-workflows
Reusable GitHub Workflows

## terraform-java-app-service.yml

Optional input `manage_deploy_slot_lifecycle` (default `false`): when `true` with `explicit_slot_swap`, starts the deploy `slot-name` before package deploy and stops it after production health checks pass, to free App Service plan memory between releases.

## Public content

Do not add organization names, product names, host names, tenant ids, or subscription ids to files.
Pass a caller-specific runner label from the caller repository.
A guard workflow scans each push.

Keep private terms in `.denylist.local` in your clone. Put one term on each line. Git ignores that file.

Run this command once in each clone:

`git config core.hooksPath .githooks`

The pre-commit hook reads `.denylist.local` and scans staged files. If that file is missing, the hook fails.

The guard workflow on each push checks built-in patterns only. Those patterns are a GUID, an email address, an Atlassian site host, and the owner prefix. The workflow does not read the private word list.
