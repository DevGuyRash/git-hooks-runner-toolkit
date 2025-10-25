# Technology Stack

## Project Type
CLI-focused toolkit composed of POSIX shell scripts, Bats test suites, and helper libraries for Git hook orchestration.

## Core Technologies

### Primary Language(s)
- **Language**: POSIX shell (Dash/Bash compatible)
- **Runtime/Compiler**: `/usr/bin/env bash` for runner scripts; Bats for test execution
- **Language-specific tools**: `bats-core`, coreutils, Git CLI

### Key Dependencies/Libraries
- **Git CLI**: Core dependency for manipulating repositories and hooks.
- **bats-core**: Test harness used across integration and audit suites.
- **GNU coreutils**: Provides portable filesystem and checksum utilities.

### Application Architecture
Runner is plugin-oriented: hook stubs invoke a shared dispatcher that enumerates executable parts. Installer CLI manages lifecycle operations (install, uninstall, stage) with flag-driven behaviour.

### Data Storage
- **Primary storage**: Filesystem directories (`.githooks`, `.git/.githooks`) for hooks and audit artefacts.
- **Data formats**: NDJSON for matrix outputs, plain text logs for Bats assertions.

### External Integrations
- **APIs**: None; shell commands interact locally with Git.
- **Protocols**: POSIX process execution and filesystem semantics.
- **Authentication**: Relies on Git credentials configured in the environment when remote operations are required (not typical for tests).

### Monitoring & Dashboard Technologies
- **Dashboard Framework**: CI pipelines ingest NDJSON; optional human-readable summaries generated via shell scripts.
- **Real-time Communication**: Standard output streaming from scripts.
- **Visualization Libraries**: None bundled; consumers may import NDJSON into preferred tooling.
- **State Management**: File-based artefacts serve as source of truth.

## Development Environment

### Build & Development Tools
- **Build System**: Shell scripts and helper Make targets when available.
- **Package Management**: Git submodules or vendoring for toolkit distribution; no external package manager required for runtime.
- **Development workflow**: Edit shell scripts, run Bats suites via `bats` or provided wrappers.

### Code Quality Tools
- **Static Analysis**: `shellcheck` (recommended, optional enforcement).
- **Formatting**: Manual formatting guided by project conventions.
- **Testing Framework**: `bats` for integration; ad-hoc shell unit assertions where needed.
- **Documentation**: Markdown within `.spec-workflow`, `docs/`, and README.

### Version Control & Collaboration
- **VCS**: Git.
- **Branching Strategy**: Trunk-based (`main`) with feature branches for changes.
- **Code Review Process**: Pull requests referencing spec workflow approvals.

### Dashboard Development
Not applicable; CLI artefacts only.

## Deployment & Distribution
- **Target Platform(s)**: Unix-like environments with POSIX shell and Git available.
- **Distribution Method**: Vendored `.githooks` directory, shared cache installs, or Git submodule.
- **Installation Requirements**: Git ≥ 2.x, POSIX shell, coreutils; optional Bats for tests.
- **Update Mechanism**: Re-run installer or update vendored toolkit via Git operations.

## Technical Requirements & Constraints

### Performance Requirements
- Installer flows should complete within seconds for typical repositories; audit suites must fit CI runtime budgets (target < 10 minutes).

### Compatibility Requirements
- **Platform Support**: Linux, macOS, and other POSIX-compliant systems.
- **Dependency Versions**: Git 2.20+ recommended; supports Bash 4+, Dash, and BusyBox ash where possible.
- **Standards Compliance**: POSIX shell portability.

### Security & Compliance
- Avoid storing secrets in hooks; rely on Git configuration for credential management.
- Ensure audit artefacts redact sensitive paths when necessary.

### Scalability & Reliability
- Designed for single-repo execution but supports shared cache installs; tests must isolate state per sandbox repo.
- Hooks and tests should recover gracefully from partial installs (idempotent reruns).

## Technical Decisions & Rationale
1. **Shell implementation**: Keeps distribution lightweight and compatible with constrained environments; alternatives (Python, Go) rejected due to dependency footprint.
2. **Bats for integration**: Aligns with existing suite making it easier to extend coverage without new tooling.
3. **NDJSON outputs**: Selected for append-only streaming and compatibility with CLI tooling; CSV rejected for limited nesting support.

## Known Limitations
- Shell scripts require careful quoting and portability auditing; lack of static typing increases regression risk.
- Bats execution time can grow with matrix permutations; needs ongoing optimisation.
