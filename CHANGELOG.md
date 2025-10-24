# Changelog

All notable changes to n8n push will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2025-10-23

### Project Launch
- **n8n push** - Initial public release
- Complete rebranding from n8n-data-manager
- New repository: tcoretech/n8n-push
- Beta release (0.1.x) to gather feedback before 1.0.0 stable release

### Added
- Comprehensive new README with accurate feature documentation
- Complete folder structure synchronization system
- Advanced manifest-based restore pipeline
- Intelligent workflow ID conflict resolution
- n8n API integration for projects, folders, and workflow assignments
- Session-based and API key authentication support
- Per-workflow Git commits with meaningful tags ([new], [updated], [deleted])
- Pre-restore snapshot with automatic rollback capability
- Dry run mode for testing operations safely
- Interactive configuration wizard
- Modular restore pipeline:
  - `lib/restore/staging.sh` - Manifest generation and ID sanitization
  - `lib/restore/folder-state.sh` - n8n state caching
  - `lib/restore/folder-sync.sh` - Recursive folder creation
  - `lib/restore/folder-assignment.sh` - Workflow-to-folder mapping
  - `lib/restore/validate.sh` - Post-import reconciliation
- Support for nested project/folder hierarchies
- GitHub path prefixing for organized repository structure
- Comprehensive test suite (ShellCheck, syntax, functional, security, documentation)
- MIT License

### Changed
- Updated all CI/CD workflows for new repository
- Modernized badge system with dynamic repository detection
- Improved configuration precedence (CLI > local > user > defaults)
- Enhanced error handling and logging throughout codebase
- Streamlined architecture documentation

### Technical Enhancements
- Complete rewrite of folder synchronization logic
- Efficient in-memory state caching for n8n projects/folders
- Smart workflow organization matching n8n UI hierarchy
- Flexible storage modes (disabled, local, remote) for all components
- Enhanced safety with validation checks at each step
- Container compatibility (Alpine and Debian-based)

---

## Historical Attribution

This project evolved from [n8n-data-manager](https://github.com/Automations-Project/n8n-data-manager) (versions 3.x and earlier) by the Automations Project. The original tool provided foundational backup and restore capabilities which have been significantly extended and rewritten in n8n push.

**Original project last version**: 4.1.0  
**Fork point**: June 2025  
**Rebranded as n8n push**: October 2025

For historical changelog entries from the original project, see `CHANGELOG.old.md`.
