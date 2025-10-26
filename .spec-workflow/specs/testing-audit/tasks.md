- [x] 1. Build CLI matrix runner for command coverage _(Approved)_
  - Files: tests/audit/cli_matrix.sh; tests/audit/lib/json_emit.sh
  - Implement permutation generation for all commands, subcommands, flags, and help variants; capture exit codes, stdout/stderr checksums, hooks-path snapshots, and overlay roots into NDJSON records.
  - _Leverage: tests/helpers/git_repo.sh; tests/lib/git_test_helpers.sh; lib/ephemeral_overlay.sh_
  - _Requirements: 1.1, 1.2, 2.1, 2.2_
  - _Prompt: Implement the task for spec testing-audit, first run spec-workflow-guide to get the workflow guide then implement the task: Role: Senior Shell Test Engineer with expertise in automation pipelines | Task: Create cli_matrix.sh and supporting json_emit.sh to enumerate every command/subcommand/flag (including help/--help) and write NDJSON case records with exit codes, checksums, hooks-path, overlay roots, and notes following requirements 1.1, 1.2, 2.1, 2.2 | Restrictions: Keep scripts POSIX-sh compatible, avoid external dependencies beyond coreutils, ensure sandbox repos from tests/helpers/git_repo.sh are torn down | _Leverage: tests/helpers/git_repo.sh, tests/lib/git_test_helpers.sh, lib/ephemeral_overlay.sh | _Requirements: 1.1, 1.2, 2.1, 2.2 | Success: All permutations execute without aborting the run, NDJSON emits deterministic IDs, overlay roots reflect precedence, discrepancies recorded in notes, scripts pass shellcheck_

- [x] 2. Add lifecycle Bats suite consuming matrix output _(Approved)_
  - Files: tests/audit/lifecycle.bats; tests/ephemeral/lifecycle.bats (update)
  - Create shared lifecycle helpers that parse matrix NDJSON and expose `expect_lifecycle_case`, `assert_overlay_precedence`, and `assert_hooks_path_restored` utilities.
  - Add `tests/audit/lifecycle.bats` to stream matrix output, iterate all install/uninstall permutations, and fail fast on hooks-path drift, manifest placement mismatches, overlay precedence errors, or truncated log entries (per Requirements 1.1, 1.3).
  - Extend `tests/ephemeral/lifecycle.bats` to source shared helpers, re-use matrix assertions for legacy permutations, and ensure diagnostics annotate failing NDJSON case IDs.
  - _Leverage: tests/ephemeral/lifecycle.bats; tests/helpers/assertions.sh; lib/ephemeral_overlay.sh_
  - _Requirements: 1.1, 1.3_
  - _Prompt: Implement the task for spec testing-audit, first run spec-workflow-guide to get the workflow guide then implement the task: Role: Bats Integration Specialist | Task: Create tests/audit/lifecycle.bats and extend tests/ephemeral/lifecycle.bats to read matrix NDJSON, assert hooks-path restoration, overlay precedence, and log completeness across install/uninstall permutations covering requirements 1.1 and 1.3 | Restrictions: Keep tests deterministic, reuse existing assertion helpers, ensure failures emit actionable diagnostics | _Leverage: tests/helpers/assertions.sh, lib/ephemeral_overlay.sh | _Requirements: 1.1, 1.3 | Success: Bats suite fails on truncated overlay logs or manifest mismatches, passes on current baseline after fixes, integrates with matrix artifacts_
  - _Approvals Needed: Requirements/design/task updates in this spec require dashboard approval once reviewed._

- [x] 3. Capture help surface snapshots and coverage checks
  - Files: tests/audit/cli_help.bats; tests/audit/lib/help_snapshot.sh; tests/audit/output/help/*.txt
  - Snapshot `help` and `--help` output for all commands and subcommands, storing checksums and identifying missing automation.
  - _Leverage: install.sh usage printers; tests/helpers/git_repo.sh_
  - _Requirements: 2.1, 2.3_
  - _Prompt: Implement the task for spec testing-audit, first run spec-workflow-guide to get the workflow guide then implement the task: Role: Shell QA Engineer focusing on CLI UX | Task: Implement help_snapshot.sh and cli_help.bats to exercise every help/--help surface, compare outputs against stored fixtures, and flag undocumented commands fulfilling requirements 2.1 and 2.3 | Restrictions: Store fixtures under tests/audit/output/help/, keep outputs trimmed of transient data, ensure tests guide contributors on regenerating fixtures | _Leverage: install.sh, tests/helpers/git_repo.sh | _Requirements: 2.1, 2.3 | Success: Tests detect new or changed help text, fixtures easy to update with documented command, coverage report lists any help surface missing automated checks_

- [x] 4. Aggregate audit findings into machine-readable reports
  - Files: tests/audit/report.sh; tests/audit/output/audit-findings.json; tests/audit/output/audit-findings.txt
  - Convert NDJSON matrix results into sorted JSON/text summaries highlighting failures, missing tests, and recommended follow-ups.
  - _Leverage: tests/audit/cli_matrix.sh; tests/audit/cli_help.bats_
  - _Requirements: 2.2, 3.3_
  - _Prompt: Implement the task for spec testing-audit, first run spec-workflow-guide to get the workflow guide then implement the task: Role: Test Reporting Specialist | Task: Build report.sh to consume matrix NDJSON, produce JSON and text summaries categorising issues (log-truncation, flag-gap, coverage-gap, alias-divergence) per requirements 2.2 and 3.3, and wire outputs into version-controlled fixtures | Restrictions: Prefer POSIX shell with optional jq fallback, ensure outputs deterministic for CI comparisons, document regen command in script header | _Leverage: tests/audit/cli_matrix.sh, tests/audit/cli_help.bats | _Requirements: 2.2, 3.3 | Success: Reports generate without manual editing, CI diff highlights new failures, summaries clearly map to requirements_

- [x] 5. Harden test harness utilities for observability
  - Files: tests/helpers/git_repo.sh; tests/lib/git_test_helpers.sh; tests/helpers/assertions.sh
  - Introduce utilities for capturing overlay logs, manifest snapshots, and environment diagnostics to reduce flakiness.
  - _Leverage: existing helper functions; lib/ephemeral_overlay.sh_
  - _Requirements: 3.1, 3.2_
  - _Prompt: Implement the task for spec testing-audit, first run spec-workflow-guide to get the workflow guide then implement the task: Role: Test Infrastructure Engineer | Task: Enhance shared helpers to capture overlay logs, manifest state, and environment data for audit tasks per requirements 3.1 and 3.2, while maintaining backward compatibility | Restrictions: Preserve POSIX shell compatibility, avoid breaking existing tests, add unit coverage for new helpers | _Leverage: tests/helpers/git_repo.sh, tests/lib/git_test_helpers.sh, lib/ephemeral_overlay.sh | _Requirements: 3.1, 3.2 | Success: New helpers expose overlay/manifest inspection APIs, existing suites remain green, added tests validate helper behaviour_

- [ ] 6. Wire audit pipeline into CI and developer workflows
  - Files: tests/audit/run.sh; package scripts or Makefile; docs/CONTRIBUTING.md (optional note only if policy allows)
  - Provide a single entry point to execute matrix + Bats suites + report generation and update CI configs or scripts to fail on new issues.
  - _Leverage: existing test runner scripts; tests/test_git_hooks_runner.sh_
  - _Requirements: 1.3, 2.2, 3.3_
  - _Prompt: Implement the task for spec testing-audit, first run spec-workflow-guide to get the workflow guide then implement the task: Role: CI Automation Engineer | Task: Create run.sh to orchestrate matrix, help, lifecycle suites, integrate with existing test commands, and update CI or local tooling to enforce audit failures per requirements 1.3, 2.2, 3.3 | Restrictions: Keep pipeline self-contained, avoid duplicating existing test logic, if documentation changes required seek explicit approval | _Leverage: tests/audit/cli_matrix.sh, tests/audit/lifecycle.bats, existing CI scripts | _Requirements: 1.3, 2.2, 3.3 | Success: Single command runs full audit, CI fails when audit-findings contain fail/missing-test entries, developers have clear guidance for remediation_
