# github-workflows
Reusable GitHub Workflows

## terraform-java-app-service.yml

Optional input `manage_deploy_slot_lifecycle` (default `false`): when `true` with `explicit_slot_swap`, starts the deploy `slot-name` before package deploy and stops it after production health checks pass, to free App Service plan memory between releases.

