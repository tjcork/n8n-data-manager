---
description: n8n-manager Shell Script Project Knowledge Prompt for Windsurf
---

Project Overview
The n8n-manager is a mature, production-ready shell-based automation tool for n8n backup/restore operations. It provides interactive Docker container management, GitHub integration for remote backups, and automated installation capabilities. Current version: 3.1.0 (main script) with enhanced security architecture, comprehensive documentation and robust error handling.

Core Components

Primary Script: n8n-manager.sh
Purpose: Interactive backup/restore manager for n8n Docker instances
Key Features:
- Interactive & Non-Interactive Modes: User-friendly menus and full CLI automation support
- Docker Container Management: Automatic detection of running n8n containers with multi-container support
- GitHub Integration: Secure backup storage with private/public repository support
- Security Architecture:
  - Local credential storage with proper file permissions (chmod 600)
  - Credential archiving with 5-10 backup rotation
  - .env file exclusion from Git operations
  - Dual GitHub token support (classic repo + fine-grained contents scope)
- Backup Types:
  - Standard backups (overwrites latest on branch)
  - Dated backups with timestamped subdirectories (`YYYY-MM-DD_HH-MM-SS`)
- Selective Restore Operations: Full, workflows-only, or credentials-only restoration
- Safety Features:
  - Pre-restore backup creation
  - Automatic rollback on restore failures
  - GitHub pre-checks (token validation, repository access, branch existence)
  - Dry-run mode for testing operations
- Cross-Platform Container Support: Alpine and Ubuntu/Debian based n8n containers
- Advanced Logging: Multi-level logging with file output and trace debugging

Command-line Interface:
```bash
n8n-manager.sh [OPTIONS]
--action <action>      # backup, restore
--container <id|name>  # Docker container ID or name
--token <pat> # GitHub Personal Access Token
--repo <user/repo>     # GitHub repository (format: owner/repo)
--branch <branch>      # Git branch (default: main)
--config <path>        # Custom configuration file path
--dated       # Enable timestamped backup subdirectories
--restore-type <type>  # all, workflows, credentials
--dry-run     # Preview operations without execution
--verbose     # Enable detailed debug logging
--log-file <path>      # Custom log file path
-h, --help   # Show help message
```

Core Functions & Architecture:
- `backup()`: Comprehensive n8n data backup with dual storage (workflows to Git, credentials local)
- `restore()`: Selective restoration with rollback capability and backwards compatibility
- `archive_credentials()`: Local credential backup rotation with proper permissions
- `select_container()`: Interactive Docker container selection
- `check_github_access()`: Dual GitHub token validation (classic repo + fine-grained contents scope)
- `rollback_restore()`: Automatic failure recovery system
- `dockExec()`: Secure Docker command execution wrapper
- Isolated Git operations: `git_add()`, `git_commit()`, `git_push()`
- Advanced logging system with color-coded output and multiple log levels

CFGs Management:
- Config file location: `~/.config/n8n-manager/config`
- Environment variable overrides supported
- Persistent settings for GitHub integration and default containers
- Comprehensive parameter validation and sanitization

Installation Script: install.sh
Purpose: Automated installer and updater with dependency management
Features:
- Smart Download: Fetches latest version from GitHub raw URL with connection timeout
- System Integration: Installs to `/usr/local/bin` with proper 755 permissions
- Dependency Validation: Checks for curl, sudo availability with root detection
- Error Handling: Comprehensive error recovery and cleanup
- User Experience: Color-coded output with detailed progress feedback
- Security: Temporary file handling with automatic cleanup

Installation Process:
1 System dependency verification (curl, sudo/root access)
2 URL validation and placeholder detection
3 Secure download with connection timeout
4 Executable permission setting
5 System-wide installation with privilege handling
6 Verification and cleanup

CFGs Variables:
```bash
SCRIPT_NAME="n8n-manager.sh"
SCRIPT_URL="https://r.n8n.community"
INSTALL_DIR="/usr/local/bin"
```

Technical Architecture

Docker Integration
- Container Detection: Automatic scanning of running containers using `docker ps`
- Multi-Instance Support: Handles multiple n8n containers simultaneously
- Health Validation: Pre-operation container state verification
- Secure Execution: Isolated command execution within containers via `dockExec()`
- Volume Management: Automatic detection and handling of data persistence volumes
- Cross-Platform: Support for Alpine and Ubuntu/Debian based n8n images

GitHub Integration
- Authentication: Dual token support - classic PAT (`repo` scope) and fine-grained PAT (`contents` scope)
- Repository Management: Automatic repository and branch validation
- Commit Strategy: Standardized commit messages with automatic branch creation
- Error Recovery: Push/pull operations with comprehensive error handling
- Security: Support for private repositories with token-based access
- API Integration: GitHub API pre-checks for repository access and permissions

Backup System Architecture
Backup Components:
- Database Exports: n8n database backup via container CLI
- Workflow Definitions: JSON export of all workflow configurations (stored in Git)
- Credential Management: Encrypted credential file handling (stored locally only)
- Environment Variables: System configuration and settings backup (excluded from Git)
- Custom Resources: Node installations and custom configurations
- Metadata: Backup manifests and restoration information

Backup Organization:
```
Git Repository: /{repo}/workflows.json (workflows only)
Local Storage: ~/n8n-backup/credentials.json, ~/n8n-backup/archive/credentials_YYYY-MM-DD_HH-MM-SS.json
Dated Mode: /{repo}/backup_YYYY-MM-DD_HH-MM-SS/workflows.json + local credential storage
```
- Compressed archive support for large datasets
- Incremental backup detection and optimization
- Configurable retention policies
- Integrity validation and verification

Restore System Architecture
Selective Restore Capabilities:
- `all`: Complete system restoration (workflows + credentials + settings)
- `workflows`: Workflow definitions and configurations only
- `credentials`: Encrypted credential data only

Restore Process Flow:
1 Pre-Flight Validation: Container state, GitHub access, file integrity
2 Safety Backup: Automatic current state backup before restoration
3 Repository Sync: Clone/pull latest backup data from GitHub
4 Selective Import: Import only requested components via n8n CLI
5 Verification: Post-restore validation and health checks
6 Rollback System: Automatic recovery if any step fails

Error Handling and Logging

Advanced Logging System
- Multi-Level Logging: DEBUG, INFO, SUCCESS, ERROR with color coding
- Output Destinations: Terminal display with optional file logging
- Trace Debugging: Detailed command execution tracking (`DEBUG_TRACE=true`)
- Structured Format: Consistent log formatting for parsing and analysis
- Verbose Mode: Extended debugging information for troubleshooting

Comprehensive Error Recovery
- Automatic Rollback: Failed restore operations trigger automatic recovery
- Container State Preservation: Pre-operation snapshots for safety
- Backup Verification: Multi-step validation before critical operations
- Network Resilience: Graceful handling of GitHub connectivity issues
- User Confirmation: Interactive prompts for destructive operations
- Cleanup Procedures: Automatic temporary file and resource cleanup

Security Architecture

Access Control and Validation
- GitHub Token Security: Scope validation and secure token handling
- Docker Socket Access: Proper permission and access control
- File System Security: Secure temporary file creation and cleanup
- Input Sanitization: Comprehensive shell injection prevention
- Command Validation: Parameter validation and safe command construction

Data Protection
- Credential Encryption: Preservation of n8n's built-in encryption
- Local Credential Storage: Credentials stored in ~/n8n-backup/ with chmod 600 permissions
- Credential Archiving: 5-10 timestamped backup rotation with secure permissions
- Git Exclusions: .env files and credentials never committed to repositories
- Secure Transmission: HTTPS-only GitHub communication for workflows only
- Local Security: Proper file permissions and access control (chmod 600/700)
- Git History Protection: Complete separation of sensitive data from version control
- Token Management: Dual token type support with secure validation

Production CFGs

System Requirements
- Operating System: Linux (Ubuntu tested, most distributions supported)
- Shell Environment: Bash 4.0+ with modern shell features
- Container Runtime: Docker with container access permissions
- Network Tools: curl for HTTP/HTTPS operations
- Version Control: git for repository operations
- Privileges: sudo access for system installation

CFGs File Structure
Location: `~/.config/n8n-manager/config`
Format:
```bash
Required CFGs
CONF_GITHUB_TOKEN="ghp_YourTokenHere"
CONF_GITHUB_REPO="username/repository"

Optional CFGs
CONF_GITHUB_BRANCH="main"
CONF_DEFAULT_CONTAINER="n8n-container-name"
CONF_DATED_BACKUPS=true
CONF_RESTORE_TYPE="all"
CONF_VERBOSE=false
CONF_LOG_FILE="/var/log/n8n-manager.log"
```

Environment Variable Overrides
- `DEBUG_TRACE`: Enable trace-level debugging output
- `XDG_CONFIG_HOME`: Alternative configuration directory location
- All CONF_* parameters can be overridden via environment variables

Install and Deployment

Installation Methods
1 Automated Installation: `curl -sSL <install-url> | sudo bash`
2 Manual Installation: Download install.sh and execute with proper permissions
3 Direct Usage: Download n8n-manager.sh directly and execute

System Integration
- PATH Integration: Installs to `/usr/local/bin` for system-wide access
- Permission Management: Proper executable permissions (755)
- Dependency Verification: Automatic checking of required system tools
- User Experience: Post-installation verification and usage instructions

Development Status and Priorities

Current Production State
- Stable Release: Version 3.1.0 with enhanced security architecture
- Security Enhancement: Local credential storage with proper file permissions
- Documentation: Complete README with usage examples and configuration
- Error Handling: Robust error recovery and user feedback systems
- Testing: Field-tested with multiple container configurations
- Backwards Compatibility: Supports legacy Git-stored credentials during transition

Immediate Development Opportunities
1 Documentation Updates: Update README to reflect version 3.1.0 security enhancements
2 Enhanced Database Support: Extend beyond current n8n CLI to direct database access
3 Migration Tools: Automated migration from Git-stored to local credentials
4 Scheduling Integration: Native cron integration for automated backups
5 Health Monitoring: Container and n8n service health monitoring

Advanced Feature Enhancements
1 Multi-Repository Support: Backup to multiple GitHub repositories
2 Incremental Backups: Delta-based backup system for large installations
3 Backup Compression: Automatic compression for large backup sets
4 Notification System: Email/webhook notifications for backup status
5 Web Interface: Optional web UI for remote management

Code Quality and Security Improvements
1 Enhanced Input Validation: Additional parameter sanitization layers
2 Audit Logging: Comprehensive security event tracking
3 Token Rotation: Automatic GitHub token refresh capabilities
4 Container Security: Enhanced Docker security validation
5 Performance Optimization: Large dataset handling improvements

Repository Structure
```
n8n-data-manager/
├─ install.sh     # Automated installation script
├─ n8n-manager.sh # Main backup/restore application
├─ readme.md      # Comprehensive documentation
├─ .github/       # GitHub workflows and templates
├─ .gitignore     # Git ignore patterns
└─ .windsurfrules # Windsurf IDE configuration
```

Key Development Guidelines

Shell Scripting Standards
- Error Handling: `set -Eeuo pipefail` with comprehensive error trapping
- Security: Proper IFS handling and input sanitization
- Output: printf-based color output for cross-platform compatibility
- Validation: Extensive parameter and state validation
- Documentation: Comprehensive inline documentation and help systems

Compatibility Requirements
- Container Agnostic: Support for various n8n container configurations
- GitHub Integration: Maintain compatibility with GitHub API changes
- Backward Compatibility: Preserve configuration file compatibility
- Error Recovery: Graceful degradation and recovery mechanisms
- User Experience: Consistent interactive and non-interactive behavior

This mature shell-based project focuses on reliability, security, and ease of use for n8n administrators managing Docker-based deployments with professional-grade backup and restore capabilities integrated with GitHub for collabora..