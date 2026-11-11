# Changelog

## [Unreleased]

### Fixed
- Preserve the original local `core.hooksPath` value and presence across repeated
  ephemeral installs and updates, so uninstall restores default, inherited, custom,
  and explicitly empty configurations correctly.
- Roll back failed installs/updates to their immediate prior configuration, and
  retain active hook assets when uninstall cannot restore a locked Git config.

### Added
- Expanded CLI help to document Ephemeral Mode prerequisites, overlay
  precedence options, and uninstall behavior.
- Refreshed `docs/ephemeral-mode.md` with step-by-step installation guidance,
  compatibility notes, troubleshooting tips, and POSIX-compliant examples.
- Highlighted Ephemeral Mode in the release notes so the new workflow is easy
  to spot when preparing upgrades.
