## Overview

Introduce a shared watcher library that powers both the existing `post-merge` example and a new `pre-commit` entrypoint, while migrating example configuration assets into a centralized `{hooks-root}/config` directory (default `.githooks/config`). The design keeps POSIX `sh` compatibility, ensures hooks share a single `watch-configured-actions.yml`, and extends tooling/tests to validate both runtime behaviour and installer behaviour across persistent and ephemeral installs.

## Steering Document Alignment

### Technical Standards (tech.md)
- Continue using POSIX `sh` and toolkit helper functions (`lib/common.sh`).
- Avoid external dependencies beyond `jq`/`yq`, retaining graceful degradation when missing.
- Maintain deterministic logging format established in existing examples.

### Project Structure (structure.md)
- Place reusable shell helpers in `lib/` alongside existing common utilities.
- Store new example entrypoint under `examples/` and matching tests under `tests/examples/` to follow current convention.
- Extend installer behaviour within `install.sh` where example staging logic resides, keeping modifications local to staging helper functions.

## Code Reuse Analysis

### Existing Components to Leverage
- **`examples/watch-configured-actions.sh`**: Source of diff evaluation, rule parsing, and execution logic to extract into reusable helper functions.
- **`lib/common.sh`**: Provides logging, repo detection, and helper routines already used by the example.
- **`install.sh` staging helpers**: Existing logic that copies example assets and respects ephemeral installs; will be extended to detect/configure centralized configs.
- **`tests/examples/common.sh`** and sandbox utilities (`ghr_*`): Reused for integration-style testing of both entrypoints under temporary repos.

### Integration Points
- **Hook Runner (`.githooks/_runner.sh`)**: No changes expected; new example will register via metadata comment for `pre-commit` so runner picks it up automatically after staging.
- **Spec Workflow**: Requirements mention doc updates; design accounts for code hooks emitting warnings when legacy config paths used, enabling docs to instruct migration.

## Architecture

1. **Shared Library Extraction**
   - Create `lib/watch-configured-actions.sh` exposing functions for config discovery, rule parsing, diff collection, and command execution.
   - Library operates on caller-provided context (hook name, diff collector) to keep entrypoints thin.
   - Existing post-merge script becomes a wrapper that sets mode-specific options then calls library.

2. **Hook Entrypoints**
   - **`examples/watch-configured-actions-post.sh`** (rename existing script or wrap) retains metadata for `post-merge`, `post-rewrite`, `post-checkout`, `post-commit` as needed.
   - **`examples/watch-configured-actions-pre-commit.sh`** new script: collects staged changes via `git diff --cached --name-only`, configures library to operate in pre-commit context, ensures mark-file handling remains optional.

3. **Centralized Config Resolution**
   - Library first looks for `${HOOKS_ROOT}/config/watch-configured-actions.yml` (and `.yaml`/`.json`) where `HOOKS_ROOT` comes from `githooks_repo_hooks_dir` (respecting ephemeral temp paths passed by runner/install).
   - Legacy fallback order preserved (.githooks/watch-config.*) with warning log urging migration.

4. **Installer Enhancements**
   - Update `install.sh stage add` example asset copier to detect directories named `config` adjacent to scripts and copy them into `{hooks-root}/config/` instead of the hook part directory.
   - Ensure copies occur per destination (hooksPath, ephemeral temp) without reusing shared global directories.

5. **Tests**
   - Add `tests/examples/watch_configured_actions_pre_commit.sh` mirroring the post-merge test but targeting staged diffs and centralized config.
   - Extend existing test utilities to expose hooks-root path for assertions.
   - Add staging test ensuring config copied to `{hooks-root}/config/watch-configured-actions.yml` in both persistent and ephemeral scenarios.

```mermaid
graph TD
    subgraph Examples
        P[watch-configured-actions-post.sh]
        C[watch-configured-actions-pre-commit.sh]
    end
    L[lib/watch-configured-actions.sh]
    I[install.sh staging helpers]
    CFG[{hooks-root}/config/watch-configured-actions.yml]

    P --> L
    C --> L
    I --> CFG
    L --> CFG
```

## Components and Interfaces

### Component 1: `lib/watch-configured-actions.sh`
- **Purpose:** Provide reusable functions for loading configs, collecting changed files, and executing rule-driven commands.
- **Interfaces:**
  - `watch_actions_init <hook-name> <hooks-root>`: sets paths, prepares temp files.
  - `watch_actions_collect_changes <mode> [args...]`: populates change list based on mode (`post`, `pre-commit`).
  - `watch_actions_run`: loads config/inline rules and executes actions, returning exit status.
- **Dependencies:** `lib/common.sh`, POSIX utilities (`mktemp`, `grep`, `awk`, `sed`, `jq|yq`).
- **Reuses:** Extracted logic from current example functions (rule parsing, pattern matching, command execution).

### Component 2: `examples/watch-configured-actions-pre-commit.sh`
- **Purpose:** `pre-commit` hook entrypoint leveraging shared library.
- **Interfaces:** CLI invoked by runner; reads `GITHOOKS_HOOK_NAME`, forwards to library.
- **Dependencies:** `lib/watch-configured-actions.sh`.
- **Reuses:** Logging/mark-file handling; diff collection specialized for staged changes.

### Component 3: Installer Staging Additions
- **Purpose:** Copy example configs into centralized location during `stage add`.
- **Interfaces:** Extend internal function (e.g., `stage_copy_example_assets`) to accept config assets and destination hooks-root.
- **Dependencies:** File system operations, existing staging metadata parsing.
- **Reuses:** Current logic that interprets `# githooks-stage` comments and replicates scripts into `.githooks/<hook>.d/`.

### Component 4: Tests (`tests/examples/watch_configured_actions_pre_commit.sh` & staging checks)
- **Purpose:** Validate new hook, shared library, and installer behaviour.
- **Interfaces:** Executed by existing test harness; uses `ghr_*` helpers.
- **Dependencies:** Test sandbox utilities, Git CLI.
- **Reuses:** Patterns from `watch_configured_actions.sh` test.

## Data Models

Configuration model remains array-based rules with keys (`name`, `patterns`, `commands`, `continue_on_error`). No schema change; tests ensure compatibility.

Mark file format stays key-value pairs as implemented; ensure library exposes consistent writer.

## Error Handling

### Error Scenario 1: Central config missing
- **Handling:** Log warning with path, exit 0 after writing mark file (if enabled).
- **User Impact:** Informative message pointing to `.githooks/config/watch-configured-actions.yml`.

### Error Scenario 2: Config parse failure (invalid YAML/JSON)
- **Handling:** Library surfaces log with offending file and underlying parser error; exit non-zero.
- **User Impact:** Pre-commit stops; message references docs/README update requirement with centralized config guidance.

### Error Scenario 3: Command execution failure
- **Handling:** Mirror existing logic—when `continue_on_error` false, exit with command status; otherwise accumulate failure bits and continue.
- **User Impact:** Consistent failure behaviour across pre and post hooks.

## Testing Strategy

### Unit Testing
- Extract pure functions (e.g., pattern-to-regex) into library; cover via shell unit tests if practical or rely on existing coverage.

### Integration Testing
- New pre-commit test that stages files, runs hook via `git commit --no-verify` override disabled to ensure enforcement.
- Update existing post-merge test to assert library integration unchanged.

### End-to-End Testing
- Extend staging CLI tests to run `install.sh stage add examples --name 'watch-configured-actions'` in persistent and ephemeral modes, asserting config placement under `{hooks-root}/config/` and warning on legacy fallbacks.
