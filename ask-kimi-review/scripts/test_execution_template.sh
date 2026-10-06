#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_file="$script_dir/../SKILL.md"
runner_file="$script_dir/run_review.sh"
tmp_file="$(mktemp -t kimi-template-test.XXXXXX)"

cleanup() {
  [[ -e "$tmp_file" ]] && /bin/unlink "$tmp_file" || true
}
trap cleanup EXIT

awk '
  /^canonical_dir\(\) \{/ { capture = 1 }
  capture { print }
  capture && /^}$/ { exit }
' "$runner_file" >"$tmp_file"

# shellcheck source=/dev/null
source "$tmp_file"

failures=0

cd() { return 1; }
set +e
fallback_path="$(canonical_dir "$script_dir")"
fallback_code=$?
set -e
unset -f cd

if [[ "$fallback_code" -ne 0 || "$fallback_path" != "$script_dir" ]]; then
  printf 'FAIL: canonical_dir must return the original path when physical resolution fails\n' >&2
  failures=$((failures + 1))
else
  printf 'PASS: canonical_dir failure fallback\n'
fi

if ! grep -Fq 'Credential `-D` params are realpath-canonicalized (falling back to the literal spelling when resolution fails); a symlinked `$HOME` or store no longer voids the deny.' "$skill_file"; then
  printf 'FAIL: missing explicit non-symlinked HOME credential-boundary assumption\n' >&2
  failures=$((failures + 1))
else
  printf 'PASS: credential HOME assumption documented\n'
fi

if [[ "$failures" -ne 0 ]]; then
  exit 1
fi

printf 'All execution-template tests passed.\n'
