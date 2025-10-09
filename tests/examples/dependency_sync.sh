#!/bin/sh
# shellcheck shell=sh

set -eu

if [ -n "${EXAMPLE_CURRENT_SCRIPT:-}" ]; then
  example_source="${EXAMPLE_CURRENT_SCRIPT}"
else
  example_source=$0
  if [ ! -f "${example_source}" ] && [ "$#" -gt 0 ] && [ -f "$1" ]; then
    example_source=$1
  fi
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "${example_source}")" && pwd)
# shellcheck source=tests/examples/common.sh
. "${SCRIPT_DIR}/common.sh"

example_tests_init

example_write_stub() {
  stub_path=$1
  log_path=$2
  cat <<EOF >"${stub_path}"
#!/bin/sh
printf '%s\n' "\$*" >> "${log_path}"
exit 0
EOF
  chmod 755 "${stub_path}"
}

example_expect_log_contains() {
  log_path=$1
  needle=$2
  log_contents=$(ghr_read_or_empty "${log_path}")
  case "${log_contents}" in
    *"${needle}"*)
      return 0
      ;;
    *)
      TEST_FAILURE_DIAG=$(printf 'log %s missing substring %s' "${log_path}" "${needle}")
      return 1
      ;;
  esac
}

example_test_dependency_sync() {
  TEST_FAILURE_DIAG=''
  tuple=$(ghr_mk_sandbox) || {
    TEST_FAILURE_DIAG='failed to create sandbox'
    return 1
  }
  old_ifs=$IFS
  IFS='|'
  set -- ${tuple}
  IFS=$old_ifs
  base=$1
  repo=$2
  remote=$3
  home=$4

  example_cleanup_dependency_sync() {
    ghr_cleanup_sandbox "$base"
  }
  trap example_cleanup_dependency_sync EXIT

  rc=0

  if [ "$rc" -eq 0 ]; then
    if ! ghr_init_repo "$repo" "$home"; then
      TEST_FAILURE_DIAG='git init failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_install_runner "$repo" "$home" "$INSTALLER" 'post-merge'; then
      TEST_FAILURE_DIAG='runner install failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    base_branch=$(ghr_git "$repo" "$home" symbolic-ref --short HEAD)
    parts_dir="$repo/.githooks/post-merge.d"
    mkdir -p "$parts_dir"
    if ! cp "$EXAMPLES_DIR/dependency-sync.sh" "$parts_dir/20-dependency-sync.sh"; then
      TEST_FAILURE_DIAG='failed to copy dependency-sync example'
      rc=1
    else
      chmod 755 "$parts_dir/20-dependency-sync.sh"
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    mkdir -p "$repo/bin"
    while IFS='|' read -r cmd log_name; do
      [ -n "${cmd}" ] || continue
      example_write_stub "$repo/bin/${cmd}" "$repo/${log_name}"
    done <<'EOF'
bun|bun.log
cargo|cargo.log
uv|uv.log
npm|npm.log
yarn|yarn.log
pnpm|pnpm.log
composer|composer.log
pip|pip.log
go|go.log
poetry|poetry.log
pipenv|pipenv.log
pdm|pdm.log
conda|conda.log
bundle|bundle.log
mix|mix.log
dotnet|dotnet.log
mvn|mvn.log
gradle|gradle.log
dart|dart.log
pod|pod.log
swift|swift.log
EOF
    example_write_stub "$repo/gradlew" "$repo/gradlew.log"
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_git "$repo" "$home" checkout -b feature >/dev/null 2>&1; then
      TEST_FAILURE_DIAG='failed to create feature branch'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    printf '{"lockfileVersion": 3}\n' >"$repo/package-lock.json"
    printf '# yarn lock\n' >"$repo/yarn.lock"
    printf '# pnpm lock\n' >"$repo/pnpm-lock.yaml"
    printf 'bunlock\n' >"$repo/bun.lock"
    printf '{"hash": "abc"}\n' >"$repo/composer.lock"
    printf 'requests==2.0.0\n' >"$repo/requirements.txt"
    printf 'module example\nrequire example.com/pkg v0.1.0\n' >"$repo/go.mod"
    printf 'example.com/pkg v0.1.0 h1:abc\n' >"$repo/go.sum"
    printf '[package]\nname = "example"\nversion = "0.1.0"\n' >"$repo/Cargo.toml"
    printf '[[package]]\nname = "example"\nversion = "0.1.0"\n' >"$repo/Cargo.lock"
    printf '[tool.poetry]\nname="example"\n' >"$repo/poetry.lock"
    printf '[[tool.pdm]]\n' >"$repo/pdm.lock"
    printf '[[tool.uv]]\n' >"$repo/uv.lock"
    printf 'name = "example"\n' >"$repo/pyproject.toml"
    printf 'source = "pypi"\n' >"$repo/Pipfile"
    printf '{}\n' >"$repo/Pipfile.lock"
    printf 'channels:\n  - defaults\n' >"$repo/environment.yml"
    printf 'source "https://rubygems.org"\n' >"$repo/Gemfile"
    printf 'GEM\n  specs:\n' >"$repo/Gemfile.lock"
    printf 'defmodule Example.MixProject do end\n' >"$repo/mix.exs"
    printf '%s\n' 'lock' >"$repo/mix.lock"
    printf '{\n  "version": 1\n}\n' >"$repo/packages.lock.json"
    printf '<Project />\n' >"$repo/Directory.Packages.props"
    mkdir -p "$repo/src"
    printf '<Project Sdk="Microsoft.NET.Sdk" />\n' >"$repo/src/App.csproj"
    printf '<project><modelVersion>4.0.0</modelVersion></project>\n' >"$repo/pom.xml"
    printf 'dependencies { }\n' >"$repo/build.gradle"
    printf 'rootProject.name="example"\n' >"$repo/settings.gradle"
    printf 'gradle-lock\n' >"$repo/gradle.lockfile"
    printf '// swift package\n' >"$repo/Package.swift"
    printf '{"pins": []}\n' >"$repo/Package.resolved"
    printf 'name: example\n' >"$repo/pubspec.yaml"
    printf '# lock\n' >"$repo/pubspec.lock"
    printf 'platform :ios, "13.0"\n' >"$repo/Podfile"
    printf 'PODS:\n' >"$repo/Podfile.lock"
    ghr_git "$repo" "$home" add .
    ghr_git "$repo" "$home" commit -q -m 'feat: add dependency manifests'
    ghr_git "$repo" "$home" checkout "$base_branch" >/dev/null 2>&1
  fi

  if [ "$rc" -eq 0 ]; then
    if ! ghr_in_repo "$repo" "$home" PATH="$repo/bin:$PATH" GITHOOKS_DEPENDENCY_SYNC_MARK_FILE=".git/change.mark" git merge --no-ff feature -q -m 'merge feature'; then
      TEST_FAILURE_DIAG='git merge failed'
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    mark="$repo/.git/change.mark"
    if [ ! -f "$mark" ]; then
      TEST_FAILURE_DIAG='dependency sync mark file missing after merge'
      rc=1
    else
      mark_contents=$(ghr_read_or_empty "$mark")
      while IFS= read -r expected_desc; do
        [ -n "$expected_desc" ] || continue
        case "$mark_contents" in
          *"trigger=${expected_desc}:"*) : ;;
          *)
            TEST_FAILURE_DIAG=$(printf 'mark file missing trigger for %s' "$expected_desc")
            rc=1
            break
            ;;
        esac
      done <<'EOF'
npm install
yarn install
pnpm install
bun install
composer install
pip install (requirements)
go mod download
cargo fetch
poetry install
pipenv sync
uv sync
pdm sync
conda env update
bundle install
mix deps.get
dotnet restore
mvn dependency:resolve
gradle dependencies
swift package resolve
dart pub get
pod install
EOF
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    while IFS='|' read -r log_name needle; do
      [ -n "$log_name" ] || continue
      log_path="$repo/${log_name}"
      if [ ! -f "$log_path" ]; then
        TEST_FAILURE_DIAG=$(printf '%s missing after merge' "$log_name")
        rc=1
        break
      fi
      if [ -n "$needle" ]; then
        if ! example_expect_log_contains "$log_path" "$needle"; then
          rc=1
          break
        fi
      fi
    done <<'EOF'
npm.log|--no-fund
yarn.log|--frozen-lockfile
pnpm.log|--frozen-lockfile
bun.log|install
composer.log|install
pip.log|-r
go.log|mod download
cargo.log|fetch
poetry.log|install
pipenv.log|sync
uv.log|sync
pdm.log|sync
conda.log|env update
bundle.log|install
mix.log|deps.get
dotnet.log|restore
mvn.log|dependency:resolve
gradlew.log|--quiet
swift.log|package resolve
dart.log|pub get
pod.log|install
EOF
  fi

  trap - EXIT
  ghr_cleanup_sandbox "$base"
  return "$rc"
}

example_register 'dependency-sync example triggers installer and mark file' example_test_dependency_sync

if [ "${EXAMPLE_TEST_RUN_MODE:-standalone}" = "standalone" ]; then
  if example_run_self; then
    exit 0
  fi
  exit 1
fi
