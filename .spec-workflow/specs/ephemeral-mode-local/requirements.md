## Introduction

Ephemeral Mode enables developers to activate the Git Hooks Runner Toolkit inside repositories they do not control, keeping all toolkit assets under local `.git/` state. It solves the pain of wanting durable hook behavior across pulls/resets while avoiding repository commits, making it safe for third-party or vendor-managed codebases.

### Problem Statement

Third-party repositories frequently forbid committed tooling. Developers need deterministic hooks (e.g., `post-merge`, `post-checkout`) that persist locally despite resets or reclones. Existing install flows require tracked files and leave manual cleanup risk, blocking adoption in external repos and consulting engagements.

### Goals

- Provide a local-only installation channel that never touches tracked files.
- Ensure hooks continue to run after `git pull`, `git reset --hard`, and similar sync operations.
- Support quick enable/disable flows so consultants and developers can move between repos effortlessly.

### Success Criteria

1. Developer installs Ephemeral Mode and immediately sees `core.hooksPath` point to `.git/.githooks/` without modifying tracked files.
2. After a `git reset --hard`, the ephemeral runner still executes configured hooks.
3. Running `install.sh uninstall --mode ephemeral` restores prior state and removes ephemeral artifacts.

### Non-Goals

- Automatically distributing hooks to other contributors or remote clones.
- Editing user shell profiles or global Git config automatically.
- Replacing versioned `.githooks/` workflows used by teams committing the toolkit.
- Providing remote bootstrap over the network.

## Alignment with Product Vision

The toolkit’s vision is portable, policy-driven automation with minimal repo churn. Ephemeral Mode widens adoption by keeping the existing runner semantics while confining artifacts to `.git/`, ensuring consistency with the product’s promise of safe, configurable hook execution.

## Requirements

### Requirement 1 — Local Durable Hooks

**User Story:** As a developer onboarding to a vendor repo, I want to enable the toolkit without committing files, so that my automation persists locally across sync operations.

#### Acceptance Criteria

1. WHEN the developer runs `install.sh --mode ephemeral` THEN the system SHALL place runner, stubs, and parts under `.git/.githooks/` and set `core.hooksPath` locally.
2. IF the repository already defines `core.hooksPath` THEN the system SHALL record and restore it on uninstall.
3. WHEN the developer performs `git pull` or `git reset --hard` THEN all ephemeral assets SHALL remain intact and hooks SHALL continue firing.

### Requirement 2 — Safe Lifecycle Management

**User Story:** As a consultant rotating across many repos, I want reversible tooling so that I can install, refresh, or remove Ephemeral Mode without breaking local state.

#### Acceptance Criteria

1. WHEN `install.sh --mode ephemeral` is run multiple times THEN the system SHALL detect existing installs and refresh contents idempotently.
2. WHEN `install.sh uninstall --mode ephemeral` is executed THEN the system SHALL delete `.git/.githooks/` artifacts it owns and restore previous hook configuration.
3. IF uninstall is invoked without prior install THEN the system SHALL print a no-op message and leave repository state unchanged.

### Requirement 3 — Overlay & Precedence Control

**User Story:** As a power user customizing hooks, I want to combine ephemeral hooks with versioned hooks, so that I can layer local automation while honoring repo defaults.

#### Acceptance Criteria

1. WHEN both ephemeral `.git/.githooks/` and versioned `.githooks/` roots exist THEN the system SHALL define a deterministic precedence order and communicate it via CLI output.
2. IF the user toggles precedence (e.g., via config or env var) THEN the runner SHALL respect it without requiring repo commits.
3. WHEN hook parts execute THEN logs SHALL identify which root contributed each script.

## Non-Functional Requirements

### Code Architecture and Modularity

- **Single Responsibility Principle:** Separate lifecycle management (install/uninstall), runner execution, and overlay resolution to simplify testing.
- **Modular Design:** Maintain reusable shell functions for config handling and directory provisioning.
- **Dependency Management:** Avoid new non-POSIX dependencies; leverage existing toolkit libraries.
- **Clear Interfaces:** Document environment variables and config keys controlling Ephemeral Mode behavior.

### Performance
- Install/refresh SHOULD complete within typical Git hook execution latency (<500ms on commodity hardware).
- Hook invocation MUST not add perceptible overhead compared to current toolkit runners.

### Security
- Ephemeral directories MUST inherit restrictive permissions (700) and respect current user ownership.
- No network calls SHALL occur during install or execution.

### Reliability
- Lifecycle scripts MUST ensure cleanup runs via shell traps even on interruption.
- Runner MUST succeed across bare repo and worktree topologies where `.git` is a file pointing to common dir.

### Usability
- CLI output SHOULD state the install location, precedence, and how to uninstall.
- Config inspection (`install.sh config show`) SHOULD reveal Ephemeral Mode status.
