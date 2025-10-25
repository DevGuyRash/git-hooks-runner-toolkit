# Product Overview

## Product Purpose
Deliver a portable, policy-friendly Git hook runner that lets teams compose, audit, and distribute hook workflows with deterministic behaviour across standard and ephemeral installs.

## Target Users
- Platform and release engineers who curate organisation-wide Git automation
- Individual contributors who need reproducible hooks without manual setup
- Compliance and audit stakeholders verifying hook provenance and logging

## Key Features
1. **Composable hook parts**: Deterministic execution order via lexical sorting and shared helpers.
2. **Install lifecycle tooling**: Single entrypoint (`install.sh`) that supports standard, ephemeral, and overlay-aware installs and uninstalls.
3. **Audit-ready observability**: Structured logging, matrix runners, and reports that capture overlays, hooks paths, and exit codes for traceability.

## Business Objectives
- Reduce support burden from flaky or misconfigured Git hooks across teams.
- Provide evidence-quality automation artefacts for compliance and release reviews.
- Maintain contributor trust by ensuring installs are reversible and self-service.

## Success Metrics
- Setup success rate: ≥ 99% installs complete without manual intervention.
- Test coverage: ≥ 95% of installer permutations exercised by automated suites.
- Time to triage hook regressions: ≤ 1 day with matrix output diagnostics.

## Product Principles
1. **Deterministic by default**: Every hook run and installer permutation should produce predictable logs and filesystem results.
2. **Portable automation**: Depend only on POSIX shell and Git so teams can adopt the toolkit in constrained environments.
3. **Audit visibility**: Capture state (hooks path, overlays, manifests) in machine-readable artefacts for quick validation.

## Monitoring & Visibility
- **Dashboard Type**: CLI-based reports and NDJSON artefacts consumed by CI dashboards.
- **Real-time Updates**: Matrix runners emit incremental NDJSON lines; CI surfaces diffs per commit.
- **Key Metrics Displayed**: Hooks-path resolution, overlay ordering, exit status trends, missing coverage.
- **Sharing Capabilities**: Commit artefacts to repo for peer review; CI attachments for broader stakeholders.

## Future Vision
### Potential Enhancements
- **Remote Access**: Optional hosted dashboard that visualises audit runs across repos.
- **Analytics**: Trend reporting on failing permutations and runtime durations.
- **Collaboration**: Inline annotations on audit artefacts to streamline follow-up fixes.
