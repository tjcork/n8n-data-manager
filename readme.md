# n8n-manager: Backup & Restore for n8n Docker via GitHub
<!-- ALL_BADGES_START -->
[![Build Status](https://img.shields.io/github/actions/workflow/status/Automations-Project/n8n-data-manager/ci.yml?branch=main&style=flat-square)](https://github.com/Automations-Project/n8n-data-manager/actions/workflows/ci.yml) [![Latest Release](https://img.shields.io/github/v/release/Automations-Project/n8n-data-manager?include_prereleases&style=flat-square&label=release)](https://github.com/Automations-Project/n8n-data-manager/releases/latest) [![ShellCheck](https://img.shields.io/badge/ShellCheck-passing-brightgreen?style=flat-square)](https://github.com/Automations-Project/n8n-data-manager/actions/workflows/ci.yml?query=branch%3Amain) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/Automations-Project/n8n-data-manager?style=flat-square&logo=github)](https://github.com/Automations-Project/n8n-data-manager/stargazers) [![GitHub Forks](https://img.shields.io/github/forks/Automations-Project/n8n-data-manager?style=flat-square&logo=github)](https://github.com/Automations-Project/n8n-data-manager/network/members) [![Contributors](https://img.shields.io/github/contributors/Automations-Project/n8n-data-manager?style=flat-square)](https://github.com/Automations-Project/n8n-data-manager/graphs/contributors) [![Open Issues](https://img.shields.io/github/issues-raw/Automations-Project/n8n-data-manager?style=flat-square&logo=github)](https://github.com/Automations-Project/n8n-data-manager/issues)
[![Last Commit](https://img.shields.io/github/last-commit/Automations-Project/n8n-data-manager/main?style=flat-square)](https://github.com/Automations-Project/n8n-data-manager/commits/main) [![Repo Size](https://img.shields.io/github/repo-size/Automations-Project/n8n-data-manager?style=flat-square)](https://github.com/Automations-Project/n8n-data-manager) [![Project Status: Active](https://img.shields.io/badge/status-active-success.svg?style=flat-square)](./#)
[![GitHub Top Language](https://img.shields.io/github/languages/top/Automations-Project/n8n-data-manager?style=flat-square)](https://github.com/Automations-Project/n8n-data-manager) [![Maintenance Status](https://img.shields.io/badge/Maintenance-Actively%20Maintained-green.svg?style=flat-square)](./#) 
<!-- ALL_BADGES_END -->

![Banner](.github/images/Banner.png)

`n8n-manager` is a robust command-line tool designed to simplify the backup and restore process for your [n8n](https://n8n.io/) instances running in Docker containers. It leverages Git and GitHub to securely store and manage your n8n workflows, credentials, and environment variables.

This script provides both interactive and non-interactive modes, making it suitable for manual use and automation/CI/CD pipelines.

## ✨ Features

*   **Interactive Mode:** User-friendly menus guide you through selecting containers and actions.
*   **Non-Interactive Mode:** Fully automatable via command-line arguments, perfect for scripting.
*   **GitHub Integration:** Backs up n8n data (workflows, credentials, environment variables) to a private or public GitHub repository.
*   **Backup Options:**
    *   **Standard Backup:** Overwrites the latest backup files on the specified branch.
    *   **Dated Backups (`--dated`):** Creates timestamped subdirectories (e.g., `backup_YYYY-MM-DD_HH-MM-SS/`) for each backup, preserving history.
*   **Restore Options:**
    *   **Full Restore:** Restores both workflows and credentials.
    *   **Selective Restore (`--restore-type`):** Restore only `workflows` or only `credentials`.
*   **Container Compatibility:**
    *   **Alpine Support:** Fully compatible with n8n containers based on Alpine Linux.
    *   **Ubuntu Support:** Works seamlessly with containers based on Ubuntu/Debian.
*   **Safety First:**
    *   **Pre-Restore Backup:** Automatically creates a temporary local backup of current data before starting a restore.
    *   **Automatic Rollback:** If the restore process fails, the script attempts to automatically roll back to the pre-restore state.
    *   **GitHub Pre-Checks:** Verifies GitHub token validity, required scopes (`repo`), repository existence, and branch existence (for restore) before proceeding.
    *   **Dry Run Mode (`--dry-run`):** Simulate backup or restore operations without making any actual changes to your n8n instance or GitHub repository.
*   **Robust Error Handling:**
    *   **Shell-Safe Operations:** All operations use explicit string comparisons and proper error checks to avoid common shell pitfalls.
    *   **Descriptive Error Messages:** Clear error messaging with specific details about what went wrong.
    *   **Improved File Validation:** Smart checks ensure n8n files are valid before attempting import operations.
*   **Configuration File:** Store default settings (token, repo, container, etc.) in `~/.config/n8n-manager/config` for convenience.
*   **Enhanced Logging:**
    *   Clear, colored output for interactive use.
    *   Verbose/Debug mode (`--verbose`) for detailed troubleshooting.
    *   Option to log all output to a file (`--log-file`).
    *   Trace mode (`--trace`) for in-depth debugging.
*   **Dependency Checks:** Verifies required tools (Docker, Git, curl) are installed on the host.
*   **Container Detection:** Automatically detects running n8n containers.

## 📋 Prerequisites

*   **Host Machine:**
    *   Linux environment (tested on Ubuntu, should work on most distributions).
    *   `docker`: To interact with the n8n container.
    *   `git`: To interact with the GitHub repository.
    *   `curl`: To perform GitHub API pre-checks.
    *   `bash`: The script interpreter.
*   **n8n Container:**
    *   Must be running.
    *   Must be based on an official n8n image (or include the `n8n` CLI tool).
    *   The `git` command is *not* required inside the container.
*   **GitHub:**
    *   A GitHub account.
    *   A GitHub repository (private recommended) to store the backups.
    *   A [GitHub Personal Access Token (PAT)](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) with the `repo` scope enabled. This scope is necessary to access repositories (both public and private) and push changes.

## 🚀 Installation

You can install `n8n-manager` using the provided installation script. This will download the main script and place it in `/usr/local/bin` for easy system-wide access.

**Note:** You need `curl` and `sudo` (or run as root) for the installation.

```bash
curl -sSL -L https://i.n8n.community | sudo bash
```

Alternatively, you can download the `n8n-manager.sh` script manually, make it executable (`chmod +x n8n-manager.sh`), and run it directly (`./n8n-manager.sh`) or place it in your desired `$PATH` directory.

## ⚙️ Configuration File (Optional)

For convenience, you can create a configuration file to store default settings. The script looks for this file at `~/.config/n8n-manager/config` by default. You can specify a different path using the `--config` argument.

Create the directory if it doesn't exist:

```bash
mkdir -p ~/.config/n8n-manager
```

Create the file `~/.config/n8n-manager/config` with content like this:

```ini
# GitHub Personal Access Token (Required)
CONF_GITHUB_TOKEN="ghp_YourGitHubPATGoesHere"

# GitHub Repository (Required, format: username/repo)
CONF_GITHUB_REPO="your-github-username/n8n-backups"

# Default GitHub Branch (Optional, defaults to main)
CONF_GITHUB_BRANCH="main"

# Default n8n Container Name or ID (Optional)
CONF_DEFAULT_CONTAINER="my-n8n-container"

# Use Dated Backups by default (Optional, true/false, defaults to false)
CONF_DATED_BACKUPS=true

# Default Restore Type (Optional, all/workflows/credentials, defaults to all)
CONF_RESTORE_TYPE="all"

# Enable Verbose Logging by default (Optional, true/false, defaults to false)
CONF_VERBOSE=false

# Log output to a file (Optional, must be an absolute path)
CONF_LOG_FILE="/var/log/n8n-manager.log"
```

**Security Note:** Ensure the configuration file has appropriate permissions (e.g., `chmod 600 ~/.config/n8n-manager/config`) as it contains your GitHub PAT.

Command-line arguments always override settings from the configuration file.

## 💡 Usage

### Interactive Mode

Simply run the script without any arguments (or only optional ones like `--verbose`):

```bash
n8n-manager.sh
```

The script will guide you through:
1.  Selecting the action (Backup/Restore).
2.  Selecting the target n8n container.
3.  Entering GitHub details (Token, Repo, Branch) if not found in the config file or provided via arguments.
4.  Confirming potentially destructive actions (like restore).

### Non-Interactive Mode

Provide all required parameters via command-line arguments. This is ideal for automation (e.g., cron jobs).

```bash
n8n-manager.sh --action <action> --container <id|name> --token <pat> --repo <user/repo> [OPTIONS]
```

**Required Arguments for Non-Interactive Use:**

*   `--action <action>`: `backup` or `restore`.
*   `--container <id|name>`: The name or ID of the running n8n Docker container.
*   `--token <pat>`: Your GitHub PAT.
*   `--repo <user/repo>`: Your GitHub repository.

**Optional Arguments:**

*   `--branch <branch>`: GitHub branch to use (defaults to `main`).
*   `--dated`: (Backup only) Create a timestamped subdirectory for the backup.
*   `--restore-type <type>`: (Restore only) Choose what to restore: `all` (default), `workflows`, or `credentials`.
*   `--dry-run`: Simulate the action without making changes.
*   `--verbose`: Enable detailed debug logging for troubleshooting.
*   `--trace`: Enable in-depth script debugging with bash execution trace.
*   `--log-file <path>`: Append all logs (plain text) to the specified file.
*   `--config <path>`: Use a custom configuration file path.
*   `-h`, `--help`: Show the help message.

**Example: Non-Interactive Backup**

```bash
n8n-manager.sh \
  --action backup \
  --container my-n8n-container \
  --token "ghp_YourToken" \
  --repo "myuser/my-n8n-backup" \
  --branch main \
  --dated \
  --log-file /var/log/n8n-backup.log
```

**Example: Non-Interactive Restore (Workflows Only)**

```bash
n8n-manager.sh \
  --action restore \
  --container my-n8n-container \
  --token "ghp_YourToken" \
  --repo "myuser/my-n8n-backup" \
  --branch main \
  --restore-type workflows
```

## 🔄 Backup & Restore Process

### Backup

1.  **Connect:** Establishes connection parameters (container, GitHub details).
2.  **Pre-Checks:** Verifies GitHub token, scopes, and repository access.
3.  **Git Prep:** Clones or fetches the specified branch into a temporary directory.
4.  **Export:** Executes `n8n export:workflow` and `n8n export:credentials` inside the container.
5.  **Environment:** Captures `N8N_` environment variables from the container.
6.  **Copy:** Copies exported `workflows.json`, `credentials.json`, and `.env` files to the temporary Git directory (optionally into a dated subdirectory).
7.  **Commit:** Commits the changes with a descriptive message including the n8n version and timestamp.
8.  **Push:** Pushes the commit to the specified GitHub repository and branch.
9.  **Cleanup:** Removes temporary files and directories.

### Restore

1.  **Connect:** Establishes connection parameters.
2.  **Pre-Checks:** Verifies GitHub token, scopes, repository, and *branch* access.
3.  **Confirmation:** Prompts the user for confirmation in interactive mode.
4.  **Pre-Restore Backup:** Exports current workflows and credentials from the container to a temporary local directory (for rollback).
5.  **Fetch:** Clones the specified branch from the GitHub repository.
6.  **Copy to Container:** Copies the `workflows.json` and/or `credentials.json` from the cloned repo to the container.
7.  **Import:** Executes `n8n import:workflow` and/or `n8n import:credentials` inside the container.
8.  **Cleanup:** Removes temporary files and directories.
9.  **Rollback (on failure):** If any step after the pre-restore backup fails, the script attempts to import the backed-up data back into n8n.

## ⚠️ Error Handling & Rollback

The script includes error trapping (`set -Eeuo pipefail`) and specific checks at various stages. Version 3.0+ includes significantly improved error handling specifically designed to address common issues in shell scripting:

- **Explicit String Comparisons**: Boolean variables and conditions now use explicit string comparisons (e.g., `[ "$variable" = "true" ]`) to avoid empty command errors.
- **Proper Return Values**: All functions have proper return values to avoid the "command not found" errors that occur with empty returns.
- **Robust Git Operations**: Git operations have been restructured to use proper error handling and to verify commands succeed at each step.
- **Alpine Container Compatibility**: Special handling for file operations in Alpine-based containers ensures compatibility regardless of container OS.

## 🔧 Container Compatibility

Version 3.0.5 includes specific improvements for working with different container environments:

### Alpine Linux Containers

Older versions of the script sometimes ran into issues with Alpine-based containers due to differences in shell behavior and file permissions. The latest version includes:

- Use of the `ash` shell for Alpine-specific commands
- More robust file existence checks before operations
- Proper handling of temporary files
- Intelligent error suppression for non-critical operations

### Best Practices for Both Container Types

For optimal performance with both Alpine and Ubuntu/Debian containers:

- Ensure the n8n CLI tool is available in the container
- Check that Docker permissions are sufficient on the host machine
- Consider using a named volume for n8n persistent data

## 📜 Logging

*   **Standard Output:** Provides colored, user-friendly status messages.
*   **Verbose Mode (`--verbose`):** Prints detailed debug information, including internal steps and command outputs.
*   **Log File (`--log-file <path>`):** Appends plain-text, timestamped logs to the specified file, suitable for auditing or background processes.

## 🤝 Contributing

Contributions are welcome! Please feel free to open issues on the GitHub repository.

## 📄 License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
