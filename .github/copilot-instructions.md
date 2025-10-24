# n8n push — AI Contributor Guide

## Quick Start

**Read the architecture first**: See `docs/ARCHITECTURE.md` for complete system design, module responsibilities, and data flows.

## Core Principles

### Code Standards
- **Strict mode**: All scripts use `set -Eeuo pipefail`
- **Logging**: Use `log LEVEL "message"` (INFO, WARN, ERROR, SUCCESS, DEBUG, DRYRUN, HEADER) - never raw `echo`
- **Config precedence**: CLI args > local `.config` > `~/.config/n8n-push/config` > defaults
- **Storage modes**: Numeric flags (0=disabled, 1=local, 2=remote) for workflows/credentials/environment
- **Temp files**: Use `mktemp` and always clean up with `rm -rf`
- **Container operations**: Use `dockExec` helper for consistent dry-run and logging behavior

### Module Boundaries
- **common.sh**: Logging, config loading, dependency checks, Docker helpers - reuse, don't duplicate
- **backup.sh / restore.sh**: Workflow/credential flows - maintain permission model (600/700)
- **n8n-api.sh**: REST API interactions - use existing auth fallback chain (API key → session credential)
- **git.sh**: All Git operations - never call `git` directly from other modules
- **restore/**: Modular pipeline - staging, folder-state, folder-sync, folder-assignment, validate

### Testing & CI
- **Local validation**: Run `tests/test-shellcheck.sh` and `tests/test-syntax.sh` before committing
- **CI pipeline**: See `.github/workflows/ci.yml` - 5 test jobs must pass
- **Test location**: All tests in `tests/` directory (not `.github/scripts/`)

### Security & Safety
- **Credentials**: Never commit to Git unless user explicitly chooses remote storage mode
- **Dry run**: All destructive operations must respect `is_dry_run` flag
- **Pre-restore backup**: Automatic snapshot and rollback capability required
- **Validation**: Post-operation checks in all major flows

## Development Workflow

1. Read relevant architecture in `docs/ARCHITECTURE.md`
2. Follow existing patterns in the module you're modifying
3. Use established helpers from `lib/common.sh`
4. Test locally with ShellCheck and syntax validation
5. Ensure CI tests pass
6. Keep changes focused and maintainable

## Key Constraints

- **No tight coupling**: Code should be adaptable; avoid hardcoding specific paths or names
- **API compatibility**: Respect n8n API contracts for projects, folders, workflows
- **Container agnostic**: Support both Alpine and Debian-based n8n containers
- **Git structure**: Preserve project/folder hierarchy in directory structure
- **Configuration flexibility**: Support interactive and non-interactive modes
