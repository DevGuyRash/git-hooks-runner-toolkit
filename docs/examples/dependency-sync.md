# dependency-sync example

## Overview

`dependency-sync.sh` watches for dependency manifest changes after merges,
rewrites, checkouts, or commits. When it detects updated lockfiles it invokes
the corresponding package manager so dependencies stay in sync.

## Stage It

```bash
.githooks/install.sh stage add examples --name 'dependency-sync'
```

The script declares `post-merge`, `post-rewrite`, `post-checkout`, and
`post-commit` in its `# githooks-stage` metadata, so staging once wires it into
all four hooks automatically.

## What It Detects

For each run the script compares the previous and current revisions:

- Node (npm / yarn / pnpm / bun) lockfiles and manifests
- Composer manifests
- Python dependency managers: `requirements*.txt`, Poetry, Pipenv, uv, and PDM
- Conda environment YAML definitions
- Go (`go.mod`, `go.sum`) and Rust (`Cargo.toml`, `Cargo.lock`)
- Ruby Bundler (`Gemfile`, `gems.rb`, lockfiles)
- Elixir (`mix.exs`, `mix.lock`)
- .NET (`packages.lock.json`, `Directory.Packages.props`, project files)
- Java (Maven `pom.xml`, Gradle settings/build files, `gradle.lockfile`)
- Swift Package Manager (`Package.swift`, `Package.resolved`)
- Dart / Flutter (`pubspec.yaml`, `pubspec.lock`)
- CocoaPods (`Podfile`, `Podfile.lock`)

When a matching file changes and the associated tool is available on `PATH`,
the script executes the appropriate install/sync command. Missing tools are
reported but do not fail the hook.

## Command Reference

| Ecosystem | Watched patterns | Command |
| --- | --- | --- |
| npm | `package-lock.json`, `npm-shrinkwrap.json`, `package.json` | `npm install --no-fund` |
| Yarn | `yarn.lock` | `yarn install --frozen-lockfile` |
| pnpm | `pnpm-lock.yaml` | `pnpm install --frozen-lockfile` |
| Bun | `bun.lock`, `bun.lockb` | `bun install` |
| Composer | `composer.lock`, `composer.json` | `composer install --no-interaction --no-progress --quiet` |
| Pip (requirements) | `requirements*.txt` | `pip install -r "$GITHOOKS_DEPENDENCY_SYNC_MATCH"` |
| Poetry | `poetry.lock`, `pyproject.toml` | `poetry install` |
| Pipenv | `Pipfile`, `Pipfile.lock` | `pipenv sync` |
| uv | `uv.lock`, `uv.toml` | `uv sync` |
| PDM | `pdm.lock` | `pdm sync` |
| Conda | `environment.yml`, `environment.yaml` | `conda env update --prune --file "$GITHOOKS_DEPENDENCY_SYNC_MATCH"` |
| Go | `go.mod`, `go.sum` | `go mod download` |
| Rust | `Cargo.toml`, `Cargo.lock` | `cargo fetch` |
| Ruby Bundler | `Gemfile`, `Gemfile.lock`, `gems.rb`, `gems.locked` | `bundle install --quiet` |
| Elixir | `mix.exs`, `mix.lock` | `mix deps.get` |
| .NET | `packages.lock.json`, `Directory.Packages.props`, `*.csproj`, `*.fsproj`, `*.vbproj`, `global.json` | `dotnet restore` |
| Maven | `pom.xml`, `pom.lock` | `mvn -B -q dependency:resolve` |
| Gradle | `build.gradle`, `settings.gradle`, `*.kts`, `gradle.lockfile` | `./gradlew --quiet dependencies` if available, else `gradle --quiet dependencies` |
| SwiftPM | `Package.swift`, `Package.resolved` | `swift package resolve` |
| Dart / Flutter | `pubspec.yaml`, `pubspec.lock` | `dart pub get` |
| CocoaPods | `Podfile`, `Podfile.lock` | `pod install` |

## Custom Recipes and Match Data

- `GITHOOKS_DEPENDENCY_SYNC_MATCH` is exported when a recipe triggers. It holds
  the first path that matched the recipe patterns so wrapper commands can pull
  the exact manifest (for example `pip install -r "$GITHOOKS_DEPENDENCY_SYNC_MATCH"`).
- Provide extra automation without editing the script through
  `GITHOOKS_DEPENDENCY_SYNC_EXTRA_RECIPES`. Supply newline-delimited entries in
  the form `patterns|description|command`, and each entry is executed with
  `sh -c` so you can reference shell syntax or the exported match variable.
- Recipes share a "description" key; repeated matches for the same description
  only execute the command once per hook run even if multiple manifests change.

## Requirements

- Git must be available (used to detect changed paths).
- Install the package managers you expect to run (e.g. `npm`, `yarn`, `pnpm`,
  `bun`, `composer`, `pip`, `poetry`, `pipenv`, `uv`, `bundle`, `mix`, `go`,
  `cargo`). Absent tools are skipped with a warning.

## Optional Mark File

Set `GITHOOKS_DEPENDENCY_SYNC_MARK_FILE` (or the legacy
`GITHOOKS_CHANGE_MARK_FILE`) to capture a small audit file whenever commands
run:

```bash
export GITHOOKS_DEPENDENCY_SYNC_MARK_FILE=.git/hooks/dependency-sync.mark
```

The mark file lists the hook name, each triggered tool, and the paths that
changed.

## Tips

- Combine with `watch-configured-actions` for bespoke automation in addition to
  dependency installers.
- Use the optional mark file to confirm which lockfiles triggered a run when
  troubleshooting.
