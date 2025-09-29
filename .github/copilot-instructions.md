# n8n-data-manager — AI contributor quickstart

## Architecture at a glance
- `n8n-manager.sh` is the entrypoint; it wires together modules from `lib/` and owns argument parsing, config resolution, and mode selection (interactive vs. non-interactive).
- `lib/common.sh` centralizes logging (`log LEVEL "msg"`), dependency checks, config loading (`load_config` with CLI > local `.config` > `~/.config/n8n-manager/config` precedence), and helpers like `dockExec` for container-safe commands. Reuse these instead of rolling new utilities.
- `lib/backup.sh` and `lib/restore.sh` contain the heavy workflow/credential flows. They depend on `dockExec`, `docker cp`, and `jq` to move data between host, container, and Git. Maintain the existing permission model (`chmod 600/700`) and archive helpers (`archive_credentials`, `archive_workflows`).
- `lib/n8n-api.sh` powers the optional folder-structure export. It can authenticate via API key or by pulling a session credential (`ensure_n8n_session_credentials`) off the container. Make sure new API calls fit the existing auth fallback chain.
- `lib/git.sh` owns commit granularity: per-workflow commits (`[new]`, `[updated]`, `[deleted]`) and bulk operations. Let it stage/commit instead of calling `git` directly elsewhere.

## Project conventions
- All scripts run with `set -Eeuo pipefail` and strict quoting. Use string booleans (`true`/`false`) and numeric storage flags (`workflows`/`credentials` = 0 disabled, 1 local, 2 remote) to stay compatible with `format_storage_value` and config parsing.
- Prefer `mktemp` for temp dirs and remember to `rm -rf` them; many functions already do this, so extend existing patterns when adding new flows.
- Use `log` levels (`INFO`, `WARN`, `ERROR`, `SUCCESS`, `DEBUG`, `DRYRUN`, `HEADER`) instead of `echo`. Respect the `verbose` flag by short-circuiting `DEBUG` logs when it is false.
- When touching container state, call `dockExec "$container_id" "cmd" $is_dry_run` so dry runs and verbose logging behave consistently.
- Folder-structured exports require `folder_structure=true`, `n8n_base_url`, and either `n8n_api_key` or a configured session credential name (`N8N_LOGIN_CREDENTIAL_NAME`). Fail fast with clear logging if these inputs are missing.
- `.gitignore` templates live in `templates/`; update them when you add new artifacts that should be kept out of Git backups.

## Developer workflows
- Lint & syntax: `./.github/scripts/test-shellcheck.sh` and `./.github/scripts/test-syntax.sh` must pass locally before opening a PR.
- Functional smoke: `./.github/scripts/test-functional.sh` spins up a disposable `n8nio/n8n:latest` container and exercises dry-run backups—ensure Docker is available before running.
- Security & docs checks live in `./.github/scripts/test-security.sh` and `./.github/scripts/test-docs.sh`; run them after editing sensitive logic or README content.
- CI mirrors these scripts in `.github/workflows/ci.yml`; keep new verification steps consistent with that workflow to avoid breakage.

## Integration touchpoints
- Docker, Git, `curl`, and `jq` are required host dependencies—`check_host_dependencies` enforces them. Mock or guard new functions accordingly.
- GitHub interactions should continue flowing through `check_github_access`, `commit_*`, and `generate_workflow_commit_message`. These handle token scopes, branch creation, and descriptive commit summaries.
- The restore pipeline assumes pre-restore backups and automatic rollback (`restore.sh`). When modifying restore logic, preserve rollback safety nets and the `--restore-type` selector.
- Sensitive files (`credentials.json`, `.env`) stay local unless the user explicitly selects remote storage. Never stage them directly—rely on the existing conditionals that honor `credentials` mode and `.gitignore` rules.
