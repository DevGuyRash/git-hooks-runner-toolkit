# Project Structure

## Directory Organization
```
project-root/
├── .githooks/                # Vendored toolkit scripts and shared runner when tracked
├── .git/.githooks/           # Ephemeral runner and overlay roots when installed in ephemeral mode
├── hooks/                    # Source hook parts staged into .githooks/
├── lib/                      # Shared shell helpers consumed by installer and tests
├── tests/                    # Automated test suites (Bats integration, helpers)
│   ├── audit/                # Audit matrix runners, lifecycle suites, reports
│   ├── ephemeral/            # Ephemeral mode-focused lifecycle tests
│   ├── helpers/              # Assertion and sandbox helpers
│   └── lib/                  # Shared test libraries
├── docs/                     # User-facing documentation and guides
└── .spec-workflow/           # Spec, steering, and approvals artefacts
```

## Naming Conventions
- **Shell scripts**: `kebab-case.sh` for executable parts, `snake_case.sh` for libraries.
- **Bats test files**: `lowercase-with-hyphen.bats` grouped by domain (e.g., `lifecycle.bats`).
- **Helpers**: `*_helpers.sh` or `lib/*.sh` indicating reusable routines.

## Import Patterns
- Test suites source helper libraries using relative paths anchored to `tests/helpers/` and `tests/lib/` to maintain portability.
- Installer scripts source shared libraries from `lib/` via `$(dirname "$0")` style path resolution.
- Avoid absolute paths within repo to support sandboxed copies.

## Code Structure Patterns
- Shell files start with shebang, `set -euo pipefail`, followed by sourced dependencies, then function definitions, and finally main execution blocks.
- Bats files organise tests using `setup_file`, `setup`, `teardown`, and named `@test` blocks grouped logically.
- Helper libraries expose functions only; they do not execute code on load.

## Code Organization Principles
1. **Single Responsibility**: Each script or test file targets one domain (e.g., lifecycle, help surfaces).
2. **Modularity**: Share reusable logic via `tests/helpers/` or `lib/`; avoid duplicating sandbox setup.
3. **Testability**: Keep installers and helpers deterministic so Bats assertions remain stable.
4. **Consistency**: Follow existing patterns for logging prefixes (`[hook]`, `[runner]`) and assertions.

## Module Boundaries
- **Installer CLI (`install.sh`)**: Public entrypoint; tests treat it as black-box command.
- **Lib helpers (`lib/*.sh`)**: Shared utilities; modifications require regression testing across suites.
- **Test harness (`tests/helpers/` + `tests/lib/`)**: Provides sandbox utilities; audit suites must rely on these functions instead of duplicating setup.
- **Audit artefacts (`tests/audit/output/`)**: Machine-readable outputs consumed by reports; production code should not depend on them.

## Code Size Guidelines
- Shell scripts: Aim for < 500 lines; break into libraries when exceeding.
- Functions: Target ≤ 50 lines; refactor complex branching into helper functions.
- Bats tests: Group related assertions within ≤ 30 lines per test for readability.

## Documentation Standards
- Spec and steering documents live under `.spec-workflow/` and proceed through approvals.
- Developer-facing docs reside in `docs/`; update only with explicit request or approval.
