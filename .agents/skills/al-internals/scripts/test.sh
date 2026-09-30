#!/usr/bin/env bash
set -euo pipefail

if ! command -v mix >/dev/null 2>&1 && [ -f "$HOME/.bashrc" ]; then
  set +u
  source "$HOME/.bashrc"
  set -u
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../../.." && pwd)"
store_dir="$(mktemp -d "${TMPDIR:-/tmp}/al-agent-test.XXXXXX")"

cleanup() {
  rm -rf "$store_dir"
}

trap cleanup EXIT
cd "$repo_root"

explicit_max_cases=false

for argument in "$@"; do
  case "$argument" in
    --max-cases|--max-cases=*) explicit_max_cases=true ;;
  esac
done

if [ "$explicit_max_cases" = false ]; then
  set -- --max-cases "${AL_TEST_MAX_CASES:-8}" "$@"
fi

AL_MNESIA_DISTRIBUTED=false AL_MNESIA_DIR="$store_dir/mnesia" mix test "$@"
