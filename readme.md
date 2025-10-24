# **n8n push**
## Organise, version, backup and restore n8n workflows and credentials

<!-- ALL_BADGES_START -->

[![Latest Release](https://img.shields.io/github/v/release/tjcork/n8n-push?style=flat-square)](https://github.com/tjcork/n8n-push/releases/latest) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE) [![GitHub Stars](https://img.shields.io/github/stars/tjcork/n8n-push?style=flat-square&logo=github)](https://github.com/tjcork/n8n-push/stargazers) [![GitHub Forks](https://img.shields.io/github/forks/tjcork/n8n-push?style=flat-square&logo=github)](https://github.com/tjcork/n8n-push/network/members) [![Contributors](https://img.shields.io/github/contributors/tjcork/n8n-push?style=flat-square)](https://github.com/tjcork/n8n-push/graphs/contributors) [![Last Commit](https://img.shields.io/github/last-commit/tjcork/n8n-push?style=flat-square)](https://github.com/tjcork/n8n-push/commits/main) [![Status: Active](https://img.shields.io/badge/status-active-success.svg?style=flat-square)](./#)

<!-- ALL_BADGES_END -->

A powerful command-line tool for backing up, restoring, and organizing self-hosted [n8n](https://n8n.io/) workflows. Synchronize your n8n folder structure to Git, maintain version control, and keep your automation workflows safely backed up.

## 🎯 What It Does



**N8N Push** bridges the gap between n8n's visual workflow interface and Git-based version control by:![Banner](.github/images/Banner.png)



- **Mirroring folder structure**: Exports workflows into a directory tree that matches your n8n project and folder organization`n8n-manager` is a robust command-line tool designed to simplify the backup and restore process for your [n8n](https://n8n.io/) instances running in Docker containers. It leverages Git and GitHub to securely store and manage your n8n workflows, credentials, and environment variables.

- **Intelligent restoration**: Recreates your complete folder hierarchy in n8n, including projects, nested folders, and workflow assignments

- **Flexible storage**: Choose local-only backups for security or Git-based backups for collaborationThis script provides both interactive and non-interactive modes, making it suitable for manual use and automation/CI/CD pipelines.

- **Version control ready**: Generates individual commits per workflow with meaningful messages (`[new]`, `[updated]`, `[deleted]`)

- **Safe operations**: Pre-restore backups with automatic rollback on failure## ✨ Features



## ✨ Key Features*   **Interactive Mode:** User-friendly menus guide you through selecting containers and actions.

*   **Non-Interactive Mode:** Fully automatable via command-line arguments, perfect for scripting.

### Smart Workflow Organization*   **GitHub Integration:** Backs up n8n data (workflows, credentials, environment variables) to a private or public GitHub repository.

- **Directory-based structure**: Workflows are organized as `ProjectName/Folder/SubFolder/WorkflowName.json`*   **Backup Options:**

- **Automatic folder sync**: Creates missing projects and folders in n8n during restore    *   **Standard Backup:** Overwrites the latest backup files on the specified branch.

- **Manifest tracking**: Maintains workflow metadata including IDs, names, and folder assignments    *   **Dated Backups (`--dated`):** Creates timestamped subdirectories (e.g., `backup_YYYY-MM-DD_HH-MM-SS/`) for each backup, preserving history.

- **Conflict resolution**: Handles workflow ID conflicts and duplicate names intelligently*   **Restore Options:**

    *   **Selective Restore:** Use `--credentials` to restore only credentials, or `--workflow` to restore only workflows. You can specify either or both flags to control exactly what gets restored.

### Flexible Backup Modes    *   **Project-Aware Restore:** Directories for projects are honored, and workflows without paths set fall back to the configured default project (`--project` flag or `N8N_PROJECT` config entry), independent of where backups live in Git.

- **Workflows**: Disabled, local-only, or Git repository storage    *   **Flexible Git Layout:** Use `N8N_PATH` (or `--github-path`) to pick a repository subdirectory for backups without changing the default project selection.

- **Credentials**: Disabled, local-only (recommended), or Git storage with encryption support*   **Container Compatibility:**

- **Environment variables**: Optional backup of n8n configuration    *   **Alpine Support:** Fully compatible with n8n containers based on Alpine Linux.

    *   **Ubuntu Support:** Works seamlessly with containers based on Ubuntu/Debian.

### Advanced Restore Capabilities*   **Safety First:**

- **Selective restore**: Restore only workflows, only credentials, or both    *   **Pre-Restore Backup:** Automatically creates a temporary local backup of current data before starting a restore.

- **ID preservation**: Option to preserve workflow IDs or generate new ones    *   **Automatic Rollback:** If the restore process fails, the script attempts to automatically roll back to the pre-restore state.

- **Folder assignment**: Automatically assigns workflows to correct folders based on directory structure    *   **GitHub Pre-Checks:** Verifies GitHub token validity, required scopes (`repo`), repository existence, and branch existence (for restore) before proceeding.

- **State reconciliation**: Validates imported workflows and updates tracking manifest    *   **Dry Run Mode (`--dry-run`):** Simulate backup or restore operations without making any actual changes to your n8n instance or GitHub repository.

*   **Robust Error Handling:**

### Git Integration    *   **Shell-Safe Operations:** All operations use explicit string comparisons and proper error checks to avoid common shell pitfalls.

- **Per-workflow commits**: Each workflow change gets its own descriptive commit    *   **Descriptive Error Messages:** Clear error messaging with specific details about what went wrong.

- **Bulk operations**: Option for single commit with all changes    *   **Improved File Validation:** Smart checks ensure n8n files are valid before attempting import operations.

- **Branch management**: Work with any branch for different environments*   **Configuration File:** Store default settings (token, repo, container, etc.) in `~/.config/n8n-manager/config` for convenience.

- **Path prefixing**: Organize backups within subdirectories of your repo*   **Enhanced Logging:**

    *   Clear, colored output for interactive use.

### API-Powered Features    *   Verbose/Debug mode (`--verbose`) for detailed troubleshooting.

- **Session or API key auth**: Flexible authentication with n8n's REST API    *   Option to log all output to a file (`--log-file`).

- **Project mapping**: Resolves project names to IDs automatically    *   Trace mode (`--trace`) for in-depth debugging.

- **Folder hierarchy**: Recursively loads and caches folder structure*   **Dependency Checks:** Verifies required tools (Docker, Git, curl) are installed on the host.

- **Workflow assignment**: Updates folder memberships via API*   **Container Detection:** Automatically detects running n8n containers.



### Safety & Reliability## 📋 Prerequisites

- **Pre-restore snapshots**: Automatic backup before any restore operation

- **Automatic rollback**: Restores previous state if import fails*   **Host Machine:**

- **Dry run mode**: Test operations without making changes    *   Linux environment (tested on Ubuntu, should work on most distributions).

- **Validation checks**: GitHub token, repository access, and n8n connectivity verification    *   `docker`: To interact with the n8n container.

- **Container compatibility**: Works with Alpine and Debian-based n8n containers    *   `git`: To interact with the GitHub repository.

    *   `curl`: To perform GitHub API pre-checks.

## 📋 Prerequisites    *   `bash`: The script interpreter.

*   **n8n Container:**

### Host Machine    *   Must be running.

- **OS**: Linux or macOS (Windows via WSL)    *   Must be based on an official n8n image (or include the `n8n` CLI tool).

- **Docker**: To interact with n8n containers    *   The `git` command is *not* required inside the container.

- **Git**: For repository operations*   **GitHub:**

- **curl**: For API requests    *   A GitHub account.

- **jq**: For JSON processing    *   A GitHub repository (private recommended) to store the backups.

- **bash**: Version 4.0 or higher    *   A [GitHub Personal Access Token (PAT)](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) with the `repo` scope enabled. This scope is necessary to access repositories (both public and private) and push changes.



### n8n Container## 🚀 Installation

- Must be running and accessible via Docker

- Based on official n8n image with CLI toolsYou can install `n8n-manager` using the provided installation script. This will download the main script and place it in `/usr/local/bin` for easy system-wide access.

- API access enabled (for folder structure features)

**Note:** You need `curl` and `sudo` (or run as root) for the installation.

### GitHub (Optional for Remote Storage)

- GitHub account with repository access```bash

- [Personal Access Token](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) with `repo` scopecurl -sSL -L https://i.n8n.community | sudo bash

```

## 🚀 Quick Start

Alternatively, you can download the `n8n-manager.sh` script manually, make it executable (`chmod +x n8n-manager.sh`), and run it directly (`./n8n-manager.sh`) or place it in your desired `$PATH` directory.

### Installation

## ⚙️ Configuration File (Optional)

```bash

# Download and install to /usr/local/binYou can bootstrap your configuration in two ways:

curl -sSL https://raw.githubusercontent.com/tjcork/n8n-workflow-organiser/main/install.sh | sudo bash

1. **Interactive wizard:** Run the script with the configure action to generate a config from guided prompts (you can choose `./.config`, the user config path, or any custom/`--config` location).

# Or clone and run directly

git clone https://github.com/tjcork/n8n-workflow-organiser.git    ```bash

cd n8n-workflow-organiser    n8n-manager.sh --action configure

chmod +x n8n-manager.sh    ```

./n8n-manager.sh

```    The same wizard is available in the interactive menu (`Configure defaults`). It captures GitHub settings when needed, workflow storage preferences, folder structure options, and writes the file with secure permissions.



### Interactive Mode2. **Manual copy/edit:** Start from the sample config if you prefer to edit values yourself.



Run without arguments for the guided wizard:For convenience, you can create a configuration file to store default settings. The script looks for this file at `~/.config/n8n-manager/config` by default. You can specify a different path using the `--config` argument.



```bashCreate the directory if it doesn't exist:

n8n-manager.sh

``````bash

mkdir -p ~/.config/n8n-manager

The wizard will help you:```

1. Select backup or restore action

2. Choose your n8n Docker containerCopy the annotated template that ships with the project and edit it to match your setup:

3. Configure storage preferences (local vs remote)

4. Set up folder structure mirroring (optional)```bash

5. Enter GitHub credentials (if using remote storage)cp .config.example ~/.config/n8n-manager/config

```

### Configuration File

Set permissions for security

Create a config file to avoid entering settings every time:```bash

chmod 600 ~/.config/n8n-manager/config

```bash```

mkdir -p ~/.config/n8n-manager

cp .config.example ~/.config/n8n-manager/configThe example file shows supported options. Open it in your editor and adjust the sections that matter:

chmod 600 ~/.config/n8n-manager/config

```*   **GitHub access:** `GITHUB_TOKEN`, `GITHUB_REPO`, and optional `GITHUB_BRANCH`, commit identity, or `GITHUB_PATH` subdirectory.

*   **Default project selection:** `N8N_PROJECT` should be the literal project name as it appears in n8n. Path-like values are treated literally now.

Or use the interactive configuration wizard:*   **Optional location :** Set `N8N_PATH` when you want to back up or restore a nested folder structure inside the chosen project; leave it empty to land at the project root.

*   **Storage modes & logging:** `WORKFLOWS`, `CREDENTIALS`, `ENVIRONMENT`, `DATED_BACKUPS`, `VERBOSE`, and related flags control how data is stored and how much output you see.

```bash*   **Folder structure export:** Configure `FOLDER_STRUCTURE`, `N8N_BASE_URL`, `N8N_API_KEY`, or `N8N_LOGIN_CREDENTIAL_NAME` if you mirror the n8n UI folder layout.

n8n-manager.sh --action configure

```**Security Note:** Ensure the configuration file has appropriate permissions (e.g., `chmod 600 ~/.config/n8n-manager/config`) as it contains your GitHub PAT. Keep the file out of version control.



Edit the config file with your settings:Command-line arguments always override settings from the configuration file.



```bashWhen restoring workflows, `n8n-manager` uses the project specified by `--project` or `N8N_PROJECT`. The workflows land inside the folder represented by `N8N_PATH` when set; otherwise, they import at the project root.

# Required for remote backups

GITHUB_TOKEN="ghp_your_token_here"## 💡 Usage

GITHUB_REPO="username/repo-name"

GITHUB_BRANCH="main"### Interactive Mode



# Container to backupSimply run the script without any arguments (or only optional ones like `--verbose`):

DEFAULT_CONTAINER="n8n-container"

```bash

# Storage modes (0=disabled, 1=local, 2=remote)n8n-manager.sh

WORKFLOWS=2          # Store in Git```

CREDENTIALS=1        # Store locally only

ENVIRONMENT=0        # Don't backupThe script will guide you through:

1.  Selecting the action (Backup/Restore).

# Folder structure mirroring2.  Selecting the target n8n container.

FOLDER_STRUCTURE=true3.  Entering GitHub details (Token, Repo, Branch) if not found in the config file or provided via arguments.

N8N_BASE_URL="http://localhost:5678"4.  Confirming potentially destructive actions (like restore).

N8N_API_KEY="n8n_api_your_key_here"

### Non-Interactive Mode

# Optional: organize within repo

GITHUB_PATH="production/"Provide all required parameters via command-line arguments. This is ideal for automation (e.g., cron jobs).

```

```bash

## 💻 Usage Examplesn8n-manager.sh --action <action> --container <id|name> --token <pat> --repo <user/repo> [OPTIONS]

```

### Backup to Git with Folder Structure

**Required Arguments for Non-Interactive Use:**

```bash

n8n-manager.sh \*   `--action <action>`: `backup` or `restore`.

  --action backup \*   `--container <id|name>`: The name or ID of the running n8n Docker container.

  --container my-n8n \*   `--token <pat>`: Your GitHub PAT.

  --token "$GITHUB_TOKEN" \*   `--repo <user/repo>`: Your GitHub repository.

  --repo "username/n8n-backups" \

  --branch main**Optional Arguments:**

```

*   `--branch <branch>`: GitHub branch to use (defaults to `main`).

This creates a directory structure in your Git repo:*   `--project <name>`: Project to target when restoring workflows unless a directory explicitly overrides it. Provide the exact name as shown in n8n; path-like values are treated literally.

*   `--dated`: (Backup only) Create a timestamped subdirectory for the backup.

```*   `--environment <mode>`: Control environment backups (`0` disabled, `1` local, `2` remote Git).

n8n-backups/*   `--dry-run`: Simulate the action without making changes.

├── Personal/*   `--verbose`: Enable detailed debug logging for troubleshooting.

│   ├── Marketing/*   `--trace`: Enable in-depth script debugging with bash execution trace.

│   │   ├── Email Campaign.json*   `--log-file <path>`: Append all logs (plain text) to the specified file.

│   │   └── Social Posts.json*   `--config <path>`: Use a custom configuration file path.

│   └── Sales/*   `-h`, `--help`: Show the help message.

│       └── Lead Processing.json

├── Client Projects/**Example: Non-Interactive Backup**

│   ├── ACME Corp/

│   │   ├── Data Import.json```bash

│   │   └── Report Generator.jsonn8n-manager.sh \

│   └── Smith Inc/  --action backup \

│       └── Invoice Automation.json  --container my-n8n-container \

└── .credentials/  --token "ghp_YourToken" \

    └── credentials.json  --repo "myuser/my-n8n-backup" \

```  --branch main \

  --dated \

### Restore with Folder Recreation  --log-file /var/log/n8n-backup.log

```

```bash

n8n-manager.sh \**Example: Non-Interactive Restore (Workflows Only)**

  --action restore \

  --container my-n8n \```bash

  --token "$GITHUB_TOKEN" \n8n-manager.sh \

  --repo "username/n8n-backups" \  --action restore \

  --branch main  --container my-n8n-container \

```  --token "ghp_YourToken" \

  --repo "myuser/my-n8n-backup" \

This will:  --branch main

1. Load your existing n8n project and folder structure```

2. Create any missing projects and folders

3. Import workflows and assign them to correct folders## 🔄 Backup & Restore Process

4. Update workflow folder assignments via API

### Backup

### Selective Restore

1.  **Connect:** Establishes connection parameters (container, GitHub details).

```bash2.  **Pre-Checks:** Verifies GitHub token, scopes, and repository access.

# Restore only workflows, skip credentials3.  **Git Prep:** Clones or fetches the specified branch into a temporary directory.

n8n-manager.sh --action restore --container my-n8n --workflows 2 --credentials 04.  **Export:** Executes `n8n export:workflow` and `n8n export:credentials` inside the container.

5.  **Environment (optional):** Captures `N8N_` environment variables when environment backups are enabled.

# Restore only credentials6.  **Copy:** Copies the selected artifacts (`workflows.json`, credentials, `.env`) into either local secure storage or the temporary Git directory, respecting each component's storage mode. Remote credentials are written to the configurable credentials folder (default: `.credentials/credentials.json`), while workflow exports remain at the repository root unless folder-structured exports are enabled.

n8n-manager.sh --action restore --container my-n8n --workflows 0 --credentials 17.  **Commit:** Commits the staged changes with a descriptive message summarizing the updated artifacts (optionally suffixed with the backup timestamp).

```8.  **Push:** Pushes the commit to the specified GitHub repository and branch.

9.  **Cleanup:** Removes temporary files and directories.

### Local-Only Backup

### Restore

```bash

# Backup to ~/n8n-backup without Git1.  **Connect:** Establishes connection parameters.

n8n-manager.sh \2.  **Pre-Checks:** Verifies GitHub token, scopes, repository, and *branch* access.

  --action backup \3.  **Confirmation:** Prompts the user for confirmation in interactive mode.

  --container my-n8n \4.  **Pre-Restore Backup:** Exports current workflows and credentials from the container to a temporary local directory (for rollback).

  --workflows 1 \5.  **Fetch:** Clones the specified branch from the GitHub repository.

  --credentials 1 \6.  **Copy to Container:** Copies the `workflows.json` and/or credentials file (from the configured folder, default `.credentials/credentials.json`) from the cloned repo to the container.

  --environment 17.  **Import:** Executes `n8n import:workflow` and/or `n8n import:credentials` inside the container.

```8.  **Cleanup:** Removes temporary files and directories.

9.  **Rollback (on failure):** If any step after the pre-restore backup fails, the script attempts to import the backed-up data back into n8n.

### Dry Run Testing

## ⚠️ Error Handling & Rollback

```bash

# Test backup without making changesThe script includes error trapping (`set -Eeuo pipefail`) and specific checks at various stages. Version 3.0+ includes significantly improved error handling specifically designed to address common issues in shell scripting:

n8n-manager.sh \

  --action backup \- **Explicit String Comparisons**: Boolean variables and conditions now use explicit string comparisons (e.g., `[ "$variable" = "true" ]`) to avoid empty command errors.

  --container my-n8n \- **Proper Return Values**: All functions have proper return values to avoid the "command not found" errors that occur with empty returns.

  --dry-run \- **Robust Git Operations**: Git operations have been restructured to use proper error handling and to verify commands succeed at each step.

  --verbose- **Alpine Container Compatibility**: Special handling for file operations in Alpine-based containers ensures compatibility regardless of container OS.

```

## 🔧 Container Compatibility

### Dated Backups

Version 3.0.5 includes specific improvements for working with different container environments:

```bash

# Create timestamped backup directory### Alpine Linux Containers

n8n-manager.sh \

  --action backup \Older versions of the script sometimes ran into issues with Alpine-based containers due to differences in shell behavior and file permissions. The latest version includes:

  --container my-n8n \

  --dated \- Use of the `ash` shell for Alpine-specific commands

  --token "$GITHUB_TOKEN" \- More robust file existence checks before operations

  --repo "username/n8n-backups"- Proper handling of temporary files

```- Intelligent error suppression for non-critical operations



Creates: `backups/backup_2025-10-22_14-30-45/`### Best Practices for Both Container Types



## 🏗️ ArchitectureFor optimal performance with both Alpine and Ubuntu/Debian containers:



### Core Components- Ensure the n8n CLI tool is available in the container

- Check that Docker permissions are sufficient on the host machine

#### Main Entry Point- Consider using a named volume for n8n persistent data

- **`n8n-manager.sh`**: Argument parsing, configuration loading, mode selection (interactive/non-interactive)

## 📜 Logging

#### Library Modules

- **`lib/common.sh`**: Logging, config management, Docker helpers, dependency checks*   **Standard Output:** Provides colored, user-friendly status messages.

- **`lib/backup.sh`**: Backup orchestration, folder structure export, Git commits*   **Verbose Mode (`--verbose`):** Prints detailed debug information, including internal steps and command outputs.

- **`lib/restore.sh`**: Restore orchestration, workflow staging, import coordination*   **Log File (`--log-file <path>`):** Appends plain-text, timestamped logs to the specified file, suitable for auditing or background processes.

- **`lib/n8n-api.sh`**: REST API client, authentication (session/API key), folder mapping

- **`lib/git.sh`**: Repository initialization, per-workflow commits, bulk operations## 🤝 Contributing

- **`lib/interactive.sh`**: Menu system, configuration wizard, user prompts

Contributions are welcome! Please feel free to open issues on the GitHub repository.

#### Restore Pipeline

- **`lib/restore/staging.sh`**: Manifest generation, workflow ID sanitization, conflict resolution## 📄 License

- **`lib/restore/folder-state.sh`**: n8n state loading, project/folder/workflow caching

- **`lib/restore/folder-sync.sh`**: Folder creation, path parsing, recursive hierarchy buildingThis project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

- **`lib/restore/folder-assignment.sh`**: Workflow-to-folder assignment via API
- **`lib/restore/validate.sh`**: Post-import reconciliation, ID tracking, metrics
- **`lib/restore/utils.sh`**: Helper functions, artifact location, sanitization

### Data Flow

#### Backup Flow
```
n8n Container → Export Individual Workflows → Fetch Folder Mapping (API)
    ↓
Organize by Project/Folder Structure → Prettify JSON → Git Add/Commit
    ↓
Per-Workflow Commits with [new]/[updated]/[deleted] Tags → Push to Remote
```

#### Restore Flow
```
Clone/Fetch Git Repo → Generate Manifest (scan directory structure)
    ↓
Load n8n State (projects, folders, workflows) via API → Cache in Memory
    ↓
Stage Workflows (sanitize IDs, resolve conflicts) → Copy to Container
    ↓
Import via n8n CLI → Reconcile IDs → Sync Folder Structure
    ↓
Create Missing Folders Recursively → Assign Workflows to Folders (API)
    ↓
Validate Results → Update Manifest → Report Metrics
```

### Configuration Precedence

Settings are resolved in this order (highest to lowest priority):
1. Command-line arguments
2. Local `.config` file (project-specific)
3. User config `~/.config/n8n-manager/config`
4. Interactive prompts
5. Built-in defaults

## 🔧 Configuration Options

### Storage Modes

All storage options support three modes:
- `0` or `disabled`: Skip this component entirely
- `1` or `local`: Store in `~/n8n-backup` (or custom path) with local rotation
- `2` or `remote`: Store in Git repository

### Environment Variables

Can be set in config file or as environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `GITHUB_TOKEN` | GitHub personal access token | - |
| `GITHUB_REPO` | Repository in `owner/name` format | - |
| `GITHUB_BRANCH` | Branch to use | `main` |
| `GITHUB_PATH` | Subdirectory within repo | - |
| `DEFAULT_CONTAINER` | n8n container name/ID | - |
| `WORKFLOWS` | Workflow storage mode (0/1/2) | `2` |
| `CREDENTIALS` | Credential storage mode (0/1/2) | `1` |
| `ENVIRONMENT` | Environment storage mode (0/1/2) | `0` |
| `FOLDER_STRUCTURE` | Enable folder mirroring | `false` |
| `N8N_BASE_URL` | n8n instance URL | - |
| `N8N_API_KEY` | n8n API key | - |
| `N8N_LOGIN_CREDENTIAL_NAME` | Credential name for session auth | - |
| `N8N_PROJECT` | Target project name | `Personal` |
| `N8N_PATH` | Path within project | - |
| `LOCAL_BACKUP_PATH` | Local backup directory | `~/n8n-backup` |
| `LOCAL_ROTATION_LIMIT` | Keep N local backups | `10` |
| `DATED_BACKUPS` | Create timestamped backups | `false` |
| `VERBOSE` | Enable debug logging | `false` |
| `DRY_RUN` | Simulate without changes | `false` |

### Command-Line Arguments

```
Usage: n8n-manager.sh [OPTIONS]

Actions:
  --action <action>           backup, restore, or configure

Container:
  --container <id|name>       Docker container name or ID

GitHub (for remote storage):
  --token <token>             GitHub personal access token
  --repo <owner/repo>         GitHub repository
  --branch <branch>           Git branch (default: main)
  --github-path <path>        Subdirectory in repo

Storage Modes:
  --workflows <mode>          0=disabled, 1=local, 2=remote
  --credentials <mode>        0=disabled, 1=local, 2=remote  
  --environment <mode>        0=disabled, 1=local, 2=remote

n8n Configuration:
  --project <name>            Target project (default: Personal)
  --n8n-path <path>           Path within project
  --folder-structure          Enable folder mirroring
  --n8n-url <url>             n8n API base URL
  --n8n-api-key <key>         n8n API key

Backup Options:
  --dated                     Create timestamped backup directory

Restore Options:
  --preserve-ids              Keep original workflow IDs
  --no-overwrite              Always generate new IDs
  --restore-type <type>       all, workflows, or credentials

Local Storage:
  --local-path <path>         Local backup directory
  --rotation <limit>          Keep N backups (0=overwrite, unlimited)

Logging:
  --verbose                   Enable debug logging
  --dry-run                   Simulate without changes
  --log-file <path>           Write logs to file

Configuration:
  --config <path>             Use custom config file
  --help, -h                  Show this help message
```

## 🔐 Security Best Practices

### Credentials Protection
1. **Never commit unencrypted credentials to Git**: Use `CREDENTIALS=1` (local-only)
2. **Use `.gitignore`**: The tool automatically manages ignore rules
3. **Secure config file**: `chmod 600 ~/.config/n8n-manager/config`
4. **Encryption option**: Set `DECRYPT_CREDENTIALS=true` in config for encrypted storage

### Token Security
1. **Use fine-grained PATs**: Grant only `repo` scope
2. **Rotate tokens regularly**: Update config file when rotating
3. **Private repositories**: Store backups in private repos when possible
4. **Environment variables**: Consider using env vars instead of config file

### API Access
1. **API key method**: Create dedicated API key in n8n settings
2. **Session method**: Use a credential stored in n8n itself
3. **Least privilege**: API access only needed for folder structure features

## 🐛 Troubleshooting

### Common Issues

**"Container not found"**
```bash
# List running containers
docker ps

# Use full container ID or exact name
n8n-manager.sh --container n8n_container_name
```

**"GitHub token invalid"**
```bash
# Test token
curl -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/user

# Verify repo scope is enabled
```

**"n8n API connection failed"**
```bash
# Check n8n is accessible
curl http://localhost:5678/api/v1/workflows

# Verify API key or credential name
N8N_API_KEY="n8n_api_..." n8n-manager.sh --action backup
```

**"Folder structure not syncing"**
```bash
# Enable verbose mode to see API calls
n8n-manager.sh --action restore --verbose --folder-structure

# Check that N8N_BASE_URL and N8N_API_KEY are set
```

**"Workflow import failed"**
```bash
# Test with dry run first
n8n-manager.sh --action restore --dry-run

# Check pre-restore backup in ~/n8n-backup/pre-restore-*
# Manually restore if needed:
docker cp ~/n8n-backup/pre-restore-*/workflows.json container:/tmp/
docker exec container n8n import:workflow --input=/tmp/workflows.json
```

### Debug Mode

Enable detailed logging:

```bash
n8n-manager.sh --action backup --verbose --log-file debug.log

# Or set in config
VERBOSE=true
```

### Getting Help

1. Check logs with `--verbose`
2. Review the `docs/ARCHITECTURE.md` for technical details
3. Open an issue on [GitHub](https://github.com/tjcork/n8n-workflow-organiser/issues)

## 📝 Development

### Project Structure

```
n8n-workflow-organiser/
├── n8n-manager.sh              # Main entry point
├── install.sh                  # Installation script
├── lib/                        # Core library modules
│   ├── backup.sh              # Backup operations
│   ├── common.sh              # Shared utilities
│   ├── decrypt.sh             # Credential decryption
│   ├── git.sh                 # Git operations
│   ├── interactive.sh         # Menu system
│   ├── n8n-api.sh             # API client
│   ├── restore.sh             # Restore orchestration
│   └── restore/               # Restore pipeline
│       ├── folder-assignment.sh
│       ├── folder-state.sh
│       ├── folder-sync.sh
│       ├── staging.sh
│       ├── utils.sh
│       └── validate.sh
├── templates/                  # .gitignore templates
├── docs/                       # Technical documentation
├── .github/
│   ├── workflows/             # CI/CD pipelines
│   └── scripts/               # Test and build scripts
└── tests/                      # Test scripts
```

### Running Tests

```bash
# Shellcheck linting
./.github/scripts/test-shellcheck.sh

# Syntax validation
./.github/scripts/test-syntax.sh

# Functional tests (requires Docker)
./.github/scripts/test-functional.sh

# Security scanning
./.github/scripts/test-security.sh

# Documentation validation
./.github/scripts/test-docs.sh
```

### Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run tests locally
5. Submit a pull request

Please ensure:
- ShellCheck passes with no errors
- Code follows existing patterns
- New features include documentation updates

## 📄 License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

This project is a significant evolution of the original [n8n-data-manager](https://github.com/Automations-Project/n8n-data-manager) by the Automations Project. The original tool provided the foundation for basic backup and restore functionality.

**Major Enhancements in n8n push:**
- Complete rewrite of folder structure synchronization
- Advanced manifest-based restore pipeline with ID conflict resolution
- Comprehensive n8n API integration for project and folder management
- Modular architecture with separate staging, validation, and assignment phases
- Intelligent workflow organization matching n8n's UI hierarchy
- Enhanced safety with pre-restore snapshots and automatic rollback
- Flexible authentication (API key and session-based)

## 🔗 Links

- **Repository**: https://github.com/tjcork/n8n-workflow-organiser
- **Issues**: https://github.com/tjcork/n8n-workflow-organiser/issues
- **n8n Documentation**: https://docs.n8n.io
- **Original Project**: https://github.com/Automations-Project/n8n-data-manager
