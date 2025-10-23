## Introduction

Deliver a POSIX-compliant example hook that runs configurable actions before commits, while consolidating example configuration files into a shared root-level `config/` directory under the installed hooks path (e.g. `.githooks/config`) so multiple hooks can reference a single `watch-configured-actions.yml`. The update must preserve existing post-merge behaviour, provide a migration path for legacy config locations, and set the stage for documentation updates that describe the centralized config convention.

## Alignment with Product Vision

Supports the toolkit goal of reusable, composable hooks by giving teams symmetry between pre- and post-commit automation and establishing clear conventions for shipping example configuration assets.

## Requirements

### Requirement 1

**User Story:** As a repository maintainer, I want a `pre-commit` example that evaluates staged changes via configurable rules, so that contributors receive immediate feedback before creating commits.

#### Acceptance Criteria

1. WHEN the example script runs during `pre-commit` THEN it SHALL inspect only staged changes and execute matching configured commands.
2. IF no rules match staged changes THEN the script SHALL exit 0 without emitting spurious logs.
3. WHEN a configured command exits non-zero AND `continue_on_error` is false THEN the script SHALL stop and propagate the failure code to Git.

### Requirement 2

**User Story:** As an installer of example hooks, I want config files to live in a central directory under the hooks install root, so that installs remain self-contained and consistent across multiple hook destinations and shared between related hook scripts.

#### Acceptance Criteria

1. WHEN `install.sh stage add examples` copies a hook that ships config files THEN the config SHALL be installed under `{hooks-root}/config/` using a shared name (e.g. `watch-configured-actions.yml`) that all related hooks can reference without duplication.
2. WHEN the installer targets multiple hook destinations (e.g. core.hooksPath plus worktree overrides or ephemeral installs) THEN each destination SHALL receive its own `{hooks-root}/config/` directory populated with the shared config files, without leaking outside the install root.
3. IF an example hook seeks configuration THEN it SHALL first search the central `{hooks-root}/config/` location before falling back to legacy paths.
4. WHEN a legacy config path is used THEN the hook SHALL emit a deprecation notice encouraging migration, without failing execution.
5. WHEN preparing release notes or documentation updates for this feature THEN requirements SHALL include adding guidance about centralized configs to the README and each affected example doc.

### Requirement 4

**User Story:** As a maintainer rolling out centralized configs, I want guardrails that ensure hooks remain discoverable and diagnosable, so that operators can debug installs even when configs are missing or misconfigured.

#### Acceptance Criteria

1. WHEN the centralized config file is absent THEN hooks SHALL log a concise hint pointing to `{hooks-root}/config/watch-configured-actions.yml` and exit successfully without running commands.
2. WHEN the centralized config file contains invalid schema THEN hooks SHALL fail with a clear error message that identifies the offending field and references the docs section to be updated.
3. WHEN runtime configuration fails to load due to permissions or sandboxing THEN hooks SHALL surface the failing path and suggest checking install mode (persistent vs ephemeral).

### Requirement 3

**User Story:** As a maintainer of the toolkit, I want automated coverage for the new behaviours, so that regressions in staging logic or hook execution are caught early.

#### Acceptance Criteria

1. WHEN running the example test suite THEN scenarios SHALL exist that cover the new pre-commit example success and failure paths.
2. WHEN staging examples in ephemeral mode within tests THEN configs SHALL remain inside the hook directory and be cleaned up automatically.
3. IF the legacy post-merge example is staged and executed THEN existing tests SHALL continue to pass.

## Non-Functional Requirements

### Code Architecture and Modularity
- **Single Responsibility Principle:** Shared watch logic SHALL live in a reusable helper, with thin hook-specific entrypoints.
- **Modular Design:** Hook scripts SHALL compose helper functions without duplicating diff or config parsing logic.
- **Dependency Management:** All scripts SHALL rely only on POSIX shell and existing toolkit helpers.
- **Clear Interfaces:** Helper APIs SHALL expose explicit functions for config discovery and change enumeration.

### Performance
- Pre-commit hook SHALL avoid extra Git commands beyond what is required to list staged changes, keeping runtime under ~1s on small repos.

### Security
- Scripts SHALL avoid executing untrusted commands unless supplied through vetted configuration entries and SHALL escape user data where logged.

### Reliability
- Hooks SHALL handle missing optional dependencies (`jq`/`yq`) gracefully and log informative warnings.

### Usability
- Hooks SHALL display actionable log messages, including clear indicators when reading configs from legacy locations.
