# Requirements Document

## Introduction

Create a dedicated testing-audit initiative that reproduces the recent Ephemeral Mode anomaly (overlay roots logging truncated paths) and expands end-to-end coverage for every installer entry point, subcommand, and flag (including all `--help` surfaces). The work should catalogue all observed failures and gaps so follow-up fixes can be planned with clear evidence.

## Alignment with Product Vision

Supports the toolkit goal of providing dependable, policy-friendly Git hook automation by hardening the verification story for install flows, overlay precedence, and hook management behaviours.

## Requirements

### Requirement 1 — Install lifecycle verification matrix

**User Story:** As a toolkit maintainer, I want a comprehensive matrix of both standard and ephemeral install/uninstall scenarios so that truncated overlay logs and similar regressions are documented with reproducible steps across every supported flag combination.

#### Acceptance Criteria

1. WHEN `install.sh install` is executed in both `standard` and `ephemeral` modes across vendored and shared-checkout contexts THEN the audit SHALL record hooks-path, overlay roots, file placements, and any mismatches (including truncated log output) with reproduction commands for every flag (`--hooks`, `--all-hooks`, `--overlay`, `--force`, `--dry-run`).
2. IF Ephemeral Mode overlay resolution is invoked with each precedence (`ephemeral-first`, `versioned-first`, `merge`) THEN the audit SHALL capture the logged order alongside filesystem assertions for each root, and contrast behaviour with the standard mode equivalents.
3. WHEN uninstall and reinstall cycles are exercised with custom `core.hooksPath` values set beforehand AND with additional flag permutations (`--dry-run`, `--mode` variations) THEN the audit SHALL document whether manifest restoration, log output, and exit codes stay consistent across runs.
4. WHEN lifecycle tests consume matrix NDJSON records for each install/uninstall permutation THEN they SHALL assert hooks-path restoration after installs and uninstalls, verify overlay root ordering matches configured precedence, and confirm manifest placement under both `.githooks/` and `.git/.githooks/` as applicable.
5. IF any matrix record indicates truncated or missing overlay log entries THEN the lifecycle suite SHALL fail with actionable diagnostics including the case identifier, offending log snippet, and expected path prefix so regressions surface immediately.

### Requirement 2 — CLI subcommand, flag, and help surface inventory

**User Story:** As a release steward, I want an inventory of every CLI subcommand, legacy alias, and option (including `--help`/`help` variants) along with its automated coverage status so that we can prioritise missing or flaky cases.

#### Acceptance Criteria

1. WHEN reviewing `install`, `uninstall`, `stage`, `hooks`, `config`, and any nested subcommands THEN the audit SHALL enumerate all documented flags and `--help`/`help` outputs, note existing automated tests, and highlight gaps or behaviour changes observed during manual execution.
2. IF a flag, subcommand, or help surface lacks automated verification THEN the audit SHALL include a failing or missing-test entry with suggested assertions, fixtures, or golden-output comparisons to add.
3. WHEN legacy aliases (`init`, `add`, `remove`) and modern subcommands are invoked with `--help` and positional `help` THEN the audit SHALL explain current behaviour, coverage status, and any divergences versus expected output.

### Requirement 3 — Test suite robustness and observability review

**User Story:** As a quality engineer, I want actionable notes on improving the test harness so that failures like the overlay log truncation surface early with clear diagnostics.

#### Acceptance Criteria

1. WHEN auditing existing Bats and shell test helpers THEN the audit SHALL list brittleness points (environment dependencies, flaky setup, insufficient assertions) and proposed mitigations.
2. IF additional logging or fixtures are required to capture overlay state, manifest contents, or CLI output THEN the audit SHALL describe these needs with concrete locations in the repo.
3. WHEN summarising findings THEN the document SHALL recommend specific follow-up fixes or new tests to be scheduled as implementation tasks in the subsequent phase.
4. WHEN lifecycle assertions detect hooks-path, overlay, or log coverage gaps THEN NDJSON `notes` SHALL capture the failure context alongside a recommended helper enhancement to close the observability gap. _(Approved)_

## Non-Functional Requirements

### Code Architecture and Modularity
- Maintain separation between audit documentation, helper utilities, and future implementation changes so subsequent fixes can target scoped modules.
- Ensure any proposed helper updates preserve the single-responsibility pattern used across `lib/` and `tests/helpers/`.

### Performance
- Audited test expansions SHOULD avoid introducing excessive runtime (target: end-to-end suite completes within current CI budget plus 10%).

### Security
- Audit steps MUST avoid exposing user-specific paths or secrets in committed artefacts; redact sensitive data when capturing logs.

### Reliability
- Findings MUST emphasise deterministic reproduction steps and required assertions so future fixes can be validated consistently across environments.

### Usability
- The resulting audit document SHOULD be consumable by contributors new to the toolkit, with clear command snippets and references to relevant scripts.
