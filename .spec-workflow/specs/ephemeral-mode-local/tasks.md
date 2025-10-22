- [x] 1. Implement Ephemeral Lifecycle shell module
  - File: lib/ephemeral_lifecycle.sh
  - Create install, refresh, and uninstall functions that manage `.git/.githooks/` provisioning, permission setting, and cleanup traps.
  - Ensure manifests capture previous `core.hooksPath` and precedence state.
  - _Leverage: lib/install_common.sh, lib/config.sh, lib/logging.sh_
  - _Requirements: Requirement 1, Requirement 2_
  - _Prompt: Implement the task for spec ephemeral-mode-local, first run spec-workflow-guide to get the workflow guide then implement the task: Role: POSIX shell engineer experienced with Git config plumbing | Task: Build lifecycle functions in lib/ephemeral_lifecycle.sh that install, refresh, and uninstall Ephemeral Mode per Requirements 1 and 2; reuse existing install_common helpers, ensure traps restore prior state, and write manifest metadata | Restrictions: Do not modify tracked hooks directories, avoid non-POSIX syntax, keep functions idempotent | _Leverage: lib/install_common.sh, lib/config.sh, lib/logging.sh | _Requirements: Requirement 1, Requirement 2 | Success: Re-running install is idempotent, uninstall restores previous config and removes ephemeral assets, unit hooks validate manifest contents_

- [x] 2. Extend CLI dispatcher for `--mode ephemeral`
  - File: install.sh
  - Add argument parsing and surface CLI messages for install/uninstall with Ephemeral Mode flags (`--hooks`, `--overlay`, `--force`, `--dry-run`).
  - Delegate to lifecycle module and print summaries including precedence info.
  - _Leverage: lib/cli_args.sh, lib/ephemeral_lifecycle.sh_
  - _Requirements: Requirement 1, Requirement 3_
  - _Prompt: Implement the task for spec ephemeral-mode-local, first run spec-workflow-guide to get the workflow guide then implement the task: Role: CLI-focused shell developer | Task: Wire `install.sh` to accept `--mode ephemeral` with appropriate options, validate mutually exclusive flags, and call lifecycle helpers while emitting concise summaries covering install location and precedence | Restrictions: Preserve existing CLI behavior for other modes, avoid duplicating logic already in helper libraries, ensure help text updates remain POSIX compliant | _Leverage: lib/cli_args.sh, lib/ephemeral_lifecycle.sh | _Requirements: Requirement 1, Requirement 3 | Success: `install.sh --mode ephemeral` installs correctly, conflicting flags error out, help output lists new options_

- [x] 3. Implement overlay precedence resolver
  - File: lib/ephemeral_overlay.sh
  - Detect available hook roots (ephemeral `.git/.githooks/parts`, versioned `.githooks`, optional extra roots) and enforce ordering toggles.
  - Provide helper to list active roots for logging and runner consumption.
  - _Leverage: lib/stage.sh, lib/config.sh_
  - _Requirements: Requirement 3_
  - _Prompt: Implement the task for spec ephemeral-mode-local, first run spec-workflow-guide to get the workflow guide then implement the task: Role: Shell architect specializing in configuration overlays | Task: Build overlay resolution helpers that gather hook roots, apply precedence rules (ephemeral-first default, configurable via config/env), and expose ordered arrays for the runner; log root order clearly | Restrictions: No hard-coded paths outside `.git/`, keep functions pure and testable, respect existing `.githooks/` if present | _Leverage: lib/stage.sh, lib/config.sh | _Requirements: Requirement 3 | Success: Overlay order logs match expectations, config toggles adjust precedence, runner receives correct roots_

- [ ] 4. Update runner invocation to honor overlay roots
  - File: _runner.sh
  - Import overlay resolver, iterate through ordered roots when executing hook parts, annotate logs with root origin.
  - Ensure behavior stays deterministic and compatible with existing stage execution.
  - _Leverage: lib/ephemeral_overlay.sh, lib/logging.sh_
  - _Requirements: Requirement 1, Requirement 3_
  - _Prompt: Implement the task for spec ephemeral-mode-local, first run spec-workflow-guide to get the workflow guide then implement the task: Role: Shell runtime maintainer | Task: Modify `_runner.sh` to query overlay roots from new helpers, iterate parts per hook with clear logging of source root, and maintain existing exit code semantics | Restrictions: Avoid regressions for non-ephemeral installs, preserve lexical ordering within each root, ensure hooks stop on non-zero when configured | _Leverage: lib/ephemeral_overlay.sh, lib/logging.sh | _Requirements: Requirement 1, Requirement 3 | Success: Runner executes overlay parts before versioned ones when configured, logs root names, existing behavior unchanged otherwise_

- [ ] 5. Add automated tests for lifecycle and runner flows
  - Files: tests/ephemeral/lifecycle.bats, tests/ephemeral/runner.bats
  - Cover install→hook execution→reset scenarios, core.hooksPath restore, overlay precedence, and uninstall cleanup.
  - Simulate bare/worktree and existing hooksPath cases.
  - _Leverage: tests/helpers/git_repo.sh, tests/helpers/assertions.sh_
  - _Requirements: Requirement 1, Requirement 2, Requirement 3_
  - _Prompt: Implement the task for spec ephemeral-mode-local, first run spec-workflow-guide to get the workflow guide then implement the task: Role: QA engineer proficient in Bats and Git fixture setup | Task: Write integration-style Bats tests covering lifecycle idempotence, persistence across Git resets, overlay precedence, existing hooksPath restoration, and uninstall cleanup | Restrictions: Keep tests POSIX-friendly, isolate temp repos per test, ensure teardown cleans artifacts | _Leverage: tests/helpers/git_repo.sh, tests/helpers/assertions.sh | _Requirements: Requirement 1, Requirement 2, Requirement 3 | Success: Tests fail on regressions, pass across supported platforms in CI, verify cleanup and precedence behavior_

- [ ] 6. Document Ephemeral Mode in CLI help and release notes
  - Files: install.sh (help section), docs/ephemeral-mode.md, CHANGELOG.md
  - Add help text snippets, usage examples, uninstall instructions, and migration notes.
  - _Leverage: existing documentation style guides_
  - _Requirements: Requirement 1, Requirement 2, Requirement 3_
  - _Prompt: Implement the task for spec ephemeral-mode-local, first run spec-workflow-guide to get the workflow guide then implement the task: Role: Technical writer with shell tooling experience | Task: Update CLI help strings and author docs covering installation steps, precedence rules, compatibility notes, and uninstall guidance | Restrictions: Preserve documentation style, avoid promises about implementation internals, ensure examples are POSIX compliant | _Leverage: existing documentation style guides | _Requirements: Requirement 1, Requirement 2, Requirement 3 | Success: Help output references Ephemeral Mode, docs include prerequisites and troubleshooting, release notes highlight feature_
