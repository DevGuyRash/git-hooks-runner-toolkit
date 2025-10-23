- [x] 1. Extract shared watcher library
  - Files: lib/watch-configured-actions.sh (new), examples/watch-configured-actions.sh
  - Move rule parsing, pattern matching, command execution, and mark-file logic into a reusable POSIX `sh` helper while adapting the existing post-event example to call the library.
  - Purpose: Prevent duplication between post-event and pre-commit hooks and enable centralized config lookup.
  - _Leverage: examples/watch-configured-actions.sh, lib/common.sh_
  - _Requirements: 1, 2, 4_
  - _Prompt: Role: POSIX Shell Developer specializing in reusable hook utilities | Task: Implement lib/watch-configured-actions.sh and refactor examples/watch-configured-actions.sh to consume it, fulfilling requirements 1, 2, and 4 by extracting shared logic and wiring centralized config discovery | Restrictions: Maintain POSIX sh compatibility, preserve existing logging semantics, do not alter behaviour for hooks not covered by requirements | _Leverage: examples/watch-configured-actions.sh, lib/common.sh_ | _Requirements: 1, 2, 4 | Success: Library provides reusable functions, existing post-event script delegates to it, tests for post-merge example keep passing_

- [ ] 2. Implement pre-commit entrypoint
  - File: examples/watch-configured-actions-pre-commit.sh (new)
  - Create a thin wrapper that gathers staged changes, invokes shared library routines, and exposes metadata for the `pre-commit` hook.
  - Purpose: Deliver pre-commit automation matching requirements while honouring centralized config.
  - _Leverage: lib/watch-configured-actions.sh, lib/common.sh_
  - _Requirements: 1, 4_
  - _Prompt: Role: Git Hooks Engineer with expertise in pre-commit workflows | Task: Add a pre-commit entrypoint using lib/watch-configured-actions.sh to inspect staged changes and execute configured actions per requirements 1 and 4 | Restrictions: Use only POSIX sh constructs, ensure staged-only diffing, keep optional mark-file behaviour intact | _Leverage: lib/watch-configured-actions.sh, lib/common.sh_ | _Requirements: 1, 4 | Success: Script runs during pre-commit, honours centralized config, exits appropriately on matches and failures_

- [ ] 3. Update installer staging for centralized configs
  - Files: install.sh, examples/config/watch-configured-actions.yml (new location)
  - Ensure example configs stage into `{hooks-root}/config/` with shared filenames for every install target (persistent and ephemeral) while emitting deprecation warnings when legacy paths are used.
  - Purpose: Align staging pipeline with centralized config requirement.
  - _Leverage: install.sh staging helpers, existing example asset layout_
  - _Requirements: 2_
  - _Prompt: Role: Shell Automation Developer focused on install tooling | Task: Modify install.sh staging logic so example configs land in {hooks-root}/config/watch-configured-actions.yml for all targets, satisfying requirement 2 | Restrictions: Preserve existing CLI flags/behaviour, handle ephemeral temp directories carefully, add warnings without breaking existing installs | _Leverage: install.sh staging helpers, examples directory structure_ | _Requirements: 2 | Success: Staging places config under central directory across install modes and legacy fallbacks warn correctly_

- [ ] 4. Expand tests for hooks and installer
  - Files: tests/examples/watch_configured_actions_pre_commit.sh (new), tests/examples/watch_configured_actions.sh, tests/test_git_hooks_examples.sh or relevant harness pieces
  - Add coverage for pre-commit execution with centralized config, verify installer copies configs correctly in persistent and ephemeral modes, and ensure existing post-event tests still pass.
  - Purpose: Guard against regressions introduced by refactor and config relocation.
  - _Leverage: tests/examples/common.sh, ghr_* sandbox utilities_
  - _Requirements: 1, 2, 3, 4_
  - _Prompt: Role: QA Engineer experienced with shell-based integration tests | Task: Extend example tests to cover new pre-commit hook and centralized config staging, fulfilling requirements 1, 2, 3, and 4 | Restrictions: Keep tests POSIX-compliant, reuse sandbox helpers, ensure deterministic assertions for config paths | _Leverage: tests/examples/common.sh, existing watch_configured_actions tests_ | _Requirements: 1, 2, 3, 4 | Success: New tests pass and fail appropriately when behaviour regresses, and existing suites remain green_

- [ ] 5. Document centralized config usage
  - Files: docs/examples/watch-configured-actions.md, README.md
  - Update documentation to explain shared `.githooks/config/watch-configured-actions.yml`, mention migration notices, and highlight pre-commit availability.
  - Purpose: Communicate new configuration conventions per requirements.
  - _Leverage: Existing docs content_
  - _Requirements: 2, 4_
  - _Prompt: Role: Technical Writer for developer tooling | Task: Revise docs to describe centralized config location, migration warnings, and new pre-commit support in alignment with requirements 2 and 4 | Restrictions: Maintain current documentation tone, avoid duplicating content, ensure instructions remain accurate for both persistent and ephemeral installs | _Leverage: docs/examples/watch-configured-actions.md, README.md_ | _Requirements: 2, 4 | Success: Documentation clearly directs users to centralized config, references new hook, and reflects runtime warnings_
