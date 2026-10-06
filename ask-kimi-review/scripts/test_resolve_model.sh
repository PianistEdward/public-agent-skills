#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
resolver="$script_dir/resolve_model.sh"
tmp_dir="$(mktemp -d -t kimi-resolver-test.XXXXXX)"

cleanup() {
  if [[ -e "$tmp_dir/kimi" ]]; then
    unlink "$tmp_dir/kimi"
  fi
  rmdir "$tmp_dir"
}
trap cleanup EXIT

cat >"$tmp_dir/kimi" <<'MOCK_KIMI'
#!/usr/bin/env bash
if [[ "${MOCK_KIMI_EXIT:-0}" != "0" ]]; then
  exit "$MOCK_KIMI_EXIT"
fi
if [[ -n "${MOCK_KIMI_JSON+x}" ]]; then
  printf '%s\n' "$MOCK_KIMI_JSON"
else
  printf '%s\n' '{}'
fi
MOCK_KIMI
chmod +x "$tmp_dir/kimi"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

expect_success() {
  local name="$1" expected="$2" requested="$3" json="$4" actual
  actual="$(PATH="$tmp_dir:$PATH" MOCK_KIMI_JSON="$json" "$resolver" "$requested")"
  [[ "$actual" == "$expected" ]] || fail "$name: expected '$expected', got '$actual'"
  printf 'PASS: %s\n' "$name"
}

expect_failure() {
  local name="$1" expected_text="$2" expected_code="$3" requested="$4" json="$5" mock_exit="${6:-0}"
  local output code
  set +e
  output="$(PATH="$tmp_dir:$PATH" MOCK_KIMI_JSON="$json" MOCK_KIMI_EXIT="$mock_exit" "$resolver" "$requested" 2>&1)"
  code=$?
  set -e
  [[ "$code" -ne 0 ]] || fail "$name: expected non-zero exit"
  [[ "$code" -eq "$expected_code" ]] || fail "$name: expected exit $expected_code, got $code"
  [[ "$output" == *"$expected_text"* ]] || fail "$name: missing '$expected_text' in '$output'"
  [[ "$output" != *"super-secret"* ]] || fail "$name: leaked provider secret"
  printf 'PASS: %s\n' "$name"
}

expect_local_failure() {
  local name="$1" expected_text="$2" expected_code="$3" path_value="$4" output code
  set +e
  output="$(PATH="$path_value" "$resolver" kimi-for-coding 2>&1)"
  code=$?
  set -e
  [[ "$code" -eq "$expected_code" ]] || fail "$name: expected exit $expected_code, got $code"
  [[ "$output" == *"$expected_text"* ]] || fail "$name: missing '$expected_text' in '$output'"
  [[ "$output" != *"super-secret"* ]] || fail "$name: leaked provider secret"
  printf 'PASS: %s\n' "$name"
}

set +e
usage_output="$($resolver 2>&1)"
usage_code=$?
set -e
[[ "$usage_code" -eq 2 ]] || fail "missing argument: expected exit 2, got $usage_code"
[[ "$usage_output" == *"Usage:"* ]] || fail "missing argument: expected usage output"
printf 'PASS: missing argument fails\n'

expect_local_failure \
  "missing kimi fails" \
  "Kimi Code CLI is not installed" \
  "3" \
  "/usr/bin:/bin"

expect_local_failure \
  "missing jq fails" \
  "jq is required" \
  "4" \
  "$tmp_dir:/bin"

expect_success \
  "exact configured alias wins" \
  "provider-a/kimi-for-coding" \
  "provider-a/kimi-for-coding" \
  '{"models":{"provider-a/kimi-for-coding":{},"provider-b/kimi-for-coding":{}}}'

expect_success \
  "exact alias wins over suffix" \
  "k3" \
  "k3" \
  '{"models":{"k3":{},"kimi-code/k3":{},"kimi-code/kimi-for-coding":{}}}'

expect_success \
  "unique suffix resolves" \
  "kimi-code/k3" \
  "k3" \
  '{"models":{"kimi-code/k3":{},"kimi-code/kimi-for-coding":{}}}'

expect_success \
  "default model unique suffix resolves" \
  "kimi-code/kimi-for-coding" \
  "kimi-for-coding" \
  '{"models":{"kimi-code/kimi-for-coding":{},"kimi-code/k3":{}}}'

expect_failure \
  "ambiguous suffix fails" \
  "Ambiguous model alias" \
  "8" \
  "kimi-for-coding" \
  '{"models":{"provider-a/kimi-for-coding":{},"provider-b/kimi-for-coding":{}}}'

expect_failure \
  "missing model fails" \
  "Model alias not found" \
  "7" \
  "missing-model" \
  '{"models":{"kimi-code/kimi-for-coding":{}}}'

expect_failure \
  "invalid schema fails without leaking secrets" \
  "Invalid provider catalog" \
  "6" \
  "kimi-for-coding" \
  '{"models":[],"api_key":"super-secret"}'

expect_failure \
  "provider failure is reported" \
  "Unable to read Kimi provider catalog" \
  "5" \
  "kimi-for-coding" \
  '{}' \
  "7"

printf 'All model resolver tests passed.\n'
