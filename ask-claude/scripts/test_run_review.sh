#!/usr/bin/env bash
set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runner="$script_dir/run_review.sh"
test_root="$(mktemp -d -t ask-claude-review-test.XXXXXX)"
fake_bin="$test_root/bin"
state_dir="$test_root/state"
failures=0

cleanup() {
  if [[ -f "$state_dir/child.pid" ]]; then
    child_pid="$(cat "$state_dir/child.pid" 2>/dev/null || true)"
    [[ -n "$child_pid" ]] && kill -KILL "$child_pid" 2>/dev/null || true
  fi
  if [[ "${KEEP_TEST_ROOT:-0}" == "1" ]]; then
    printf 'Preserved test root: %s\n' "$test_root"
  else
    rm -rf "$test_root"
  fi
}
trap cleanup EXIT

mkdir -p "$fake_bin" "$state_dir"

cat >"$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -u

if [[ "${1:-}" == "--version" ]]; then
  printf '%s\n' '2.1.210 (Fake Claude Code)'
  exit 0
fi

debug_file=""
for ((arg_index=1; arg_index <= $#; arg_index++)); do
  if [[ "${!arg_index:-}" == "--debug-file" ]]; then
    next_index=$((arg_index + 1))
    debug_file="${!next_index:-}"
  fi
done

emit_success() {
  cat <<'JSON'
{"type":"result","subtype":"success","is_error":false,"session_id":"fake-session","duration_ms":1234,"duration_api_ms":900,"result":"review complete","structured_output":{"verdict":"PASS","findings":[],"caveats":[],"next_steps":[]},"usage":{"input_tokens":10,"output_tokens":20},"modelUsage":{"deepseek-v4-pro":{"inputTokens":10,"outputTokens":20}},"tool_usage":{"Read":{"count":3,"failed":0},"Bash":{"count":2,"failed":1}},"permission_denials":[],"terminal_reason":"completed"}
JSON
}

emit_success_without_tools() {
  cat <<'JSON'
{"type":"result","subtype":"success","is_error":false,"session_id":"fake-session","duration_ms":1234,"duration_api_ms":900,"result":"review complete","structured_output":{"verdict":"PASS","findings":[],"caveats":[],"next_steps":[]},"usage":{"input_tokens":10,"output_tokens":20},"modelUsage":{"deepseek-v4-pro":{"inputTokens":10,"outputTokens":20}},"permission_denials":[],"terminal_reason":"completed"}
JSON
}

case "${FAKE_SCENARIO:-success}" in
  success)
    emit_success
    ;;
  nonzero)
    printf 'provider failed\n' >&2
    exit 7
    ;;
  empty)
    exit 0
    ;;
  invalid-json)
    printf 'not json\n'
    ;;
  invalid-terminal)
    printf '%s\n' '{"structured_output":{"verdict":"PASS","findings":[],"caveats":[],"next_steps":[]},"terminal_reason":"unknown"}'
    ;;
  invalid-structured)
    printf '%s\n' '{"structured_output":{"verdict":"PASS","findings":"none","caveats":[],"next_steps":[]},"modelUsage":{"fake-model":{}},"terminal_reason":"completed"}'
    ;;
  is-error)
    printf '%s\n' '{"is_error":true,"structured_output":{"verdict":"PASS","findings":[],"caveats":[],"next_steps":[]},"modelUsage":{"fake-model":{}},"terminal_reason":"completed"}'
    ;;
  fractional-line)
    printf '%s\n' '{"structured_output":{"verdict":"NEEDS_ATTENTION","findings":[{"severity":"P2","file":"a.txt","line":1.5,"issue":"fractional line","recommendation":"fix"}],"caveats":[],"next_steps":[]},"modelUsage":{"fake-model":{}},"terminal_reason":"completed"}'
    ;;
  negative-line)
    printf '%s\n' '{"structured_output":{"verdict":"NEEDS_ATTENTION","findings":[{"severity":"P2","file":"a.txt","line":-5,"issue":"negative line","recommendation":"fix"}],"caveats":[],"next_steps":[]},"modelUsage":{"fake-model":{}},"terminal_reason":"completed"}'
    ;;
  extra-field)
    printf '%s\n' '{"structured_output":{"verdict":"PASS","findings":[],"caveats":[],"next_steps":[],"unexpected":true},"modelUsage":{"fake-model":{}},"terminal_reason":"completed"}'
    ;;
  secret-output)
    printf '%s\n' '{"result":"Authorization: Bearer review-secret-value-123456","structured_output":{"verdict":"PASS","findings":[],"caveats":["Authorization: Bearer review-secret-value-123456"],"next_steps":[]},"modelUsage":{"fake-model":{}},"terminal_reason":"completed"}'
    ;;
  delayed-success)
    sleep 2
    emit_success
    ;;
  debug-tools)
    if [[ -n "$debug_file" ]]; then
      printf '%s\n' \
        '2026-07-27T04:45:02.210Z [INFO] [Stall] tool_dispatch_end tool=Read toolUseId=call_00_example outcome=ok durationMs=2' \
        '2026-07-27T04:50:23.082Z [INFO] [Stall] tool_dispatch_end tool=Bash toolUseId=call_01_example outcome=error durationMs=44' >"$debug_file"
    fi
    emit_success_without_tools
    ;;
  debug-tools-malformed)
    if [[ -n "$debug_file" ]]; then
      printf '%s\n' '2026-07-27T04:45:02.210Z [INFO] tool_dispatch_end malformed-record' >"$debug_file"
    fi
    emit_success_without_tools
    ;;
  debug-tools-mixed)
    if [[ -n "$debug_file" ]]; then
      printf '%s\n' \
        '2026-07-27T04:45:02.210Z [INFO] tool_dispatch_end tool=Read toolUseId=call_00_example outcome=ok durationMs=2' \
        '2026-07-27T04:50:23.082Z [INFO] tool_dispatch_end malformed-record' >"$debug_file"
    fi
    emit_success_without_tools
    ;;
  debug-tools-secret)
    if [[ -n "$debug_file" ]]; then
      printf '%s\n' 'Authorization: Bearer debug-secret-value-123456' >"$debug_file"
    fi
    emit_success_without_tools
    ;;
  capture-args)
    printf '%s\n' "$@" >"$FAKE_STATE_DIR/claude.args"
    emit_success
    ;;
  sleep)
    sleep 30
    ;;
  kill-after-ignore)
    # a wedged provider that ignores the TERM from timeout(1) forces the
    # kill-after SIGKILL path (coreutils exits 137, not 124)
    trap '' TERM
    sleep 30
    ;;
  descendant)
    sleep 30 &
    printf '%s\n' "$!" >"$FAKE_STATE_DIR/child.pid"
    wait
    ;;
  descendant-orphan)
    # spawns a long-lived child while alive so the tree sampler records it,
    # then exits: the child is reparented to launchd before finalization, so
    # cleanup must terminate it via reparent-stable identity fields (ppid in
    # the identity would misclassify the orphan as a reused pid and leave it)
    sleep 30 &
    printf '%s\n' "$!" >"$FAKE_STATE_DIR/orphan.pid"
    sleep 0.6
    emit_success
    exit 0
    ;;
  descendant-orphan-killignore)
    # same shape, but one reparented child ignores TERM entirely: the runner's
    # own KILL leg (0.2s after the TERM pass) must stop it from memory
    sleep 30 &
    printf '%s\n' "$!" >"$FAKE_STATE_DIR/orphan.pid"
    bash -c 'trap "" TERM; sleep 30' &
    printf '%s\n' "$!" >"$FAKE_STATE_DIR/orphan2.pid"
    sleep 0.6
    emit_success
    exit 0
    ;;
  mutate)
    printf 'mutation\n' >>"$FAKE_REPO/tracked.txt" 2>"$FAKE_STATE_DIR/mutation.err" || true
    emit_success
    ;;
  mutate-sibling)
    printf 'mutation\n' >>"$FAKE_REPO/reviews/sibling.md" 2>"$FAKE_STATE_DIR/mutation.err" || true
    emit_success
    ;;
  *)
    printf 'unknown fake scenario: %s\n' "$FAKE_SCENARIO" >&2
    exit 64
    ;;
esac
FAKE_CLAUDE
chmod +x "$fake_bin/claude"

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label (expected '$expected', got '$actual')"
  fi
}

assert_file() {
  local path="$1" label="$2"
  if [[ -f "$path" ]]; then
    pass "$label"
  else
    fail "$label (missing $path)"
  fi
}

assert_jq() {
  local expression="$1" path="$2" label="$3"
  if jq -e "$expression" "$path" >/dev/null 2>&1; then
    pass "$label"
  else
    fail "$label ($expression in $path)"
  fi
}

assert_contains() {
  local pattern="$1" path="$2" label="$3"
  if /usr/bin/grep -aEq -- "$pattern" "$path" 2>/dev/null; then
    pass "$label"
  else
    fail "$label (missing pattern in $path)"
  fi
}

assert_not_contains() {
  local pattern="$1" path="$2" label="$3" scan_code
  /usr/bin/grep -aEq -- "$pattern" "$path" 2>/dev/null
  scan_code=$?
  case "$scan_code" in
    0) fail "$label (found sensitive pattern in $path)" ;;
    1) pass "$label" ;;
    *) fail "$label (unable to scan $path, grep exit $scan_code)" ;;
  esac
}

if (failures=0; assert_not_contains 'secret' "$test_root/missing-assert-file" "missing file fails closed" >/dev/null 2>&1; [[ "$failures" -eq 1 ]]); then
  pass "assert_not_contains fails closed on unreadable input"
else
  fail "assert_not_contains fails closed on unreadable input"
fi

new_repo() {
  local name="$1" repo
  repo="$test_root/$name"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  printf 'baseline\n' >"$repo/tracked.txt"
  git -C "$repo" add tracked.txt
  git -C "$repo" commit -qm baseline
  printf '%s\n' "$repo"
}

run_review() {
  local scenario="$1" repo="$2" artifact="$3" timeout_value="$4"
  shift 4
  FAKE_SCENARIO="$scenario" \
  FAKE_STATE_DIR="$state_dir" \
  FAKE_REPO="$repo" \
  ANTHROPIC_BASE_URL="https://token-value@api.deepseek.com/anthropic" \
  ASK_CLAUDE_BIN="$fake_bin/claude" \
    "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout "$timeout_value" "$@"
}

if [[ ! -x "$runner" ]]; then
  fail "review runner exists and is executable"
  printf '%s\n' "Regression suite is RED: implement $runner"
  exit 1
fi

ripgrep_command='r''g'
if /usr/bin/grep -aEq "(^|[[:space:]])${ripgrep_command}([[:space:]]|$)" "$0"; then
  fail "regression suite has no optional ripgrep dependency"
else
  pass "regression suite has no optional ripgrep dependency"
fi

cleanup_call_count="$(/usr/bin/grep -aEc '^[[:space:]]*release_tracked_processes([[:space:]]|$)' "$runner")"
assert_eq 1 "$cleanup_call_count" "finalize is the single normal cleanup owner"

repo="$(new_repo success-repo)"
artifact="$repo/reviews/success.md"
run_review success "$repo" "$artifact" 30m >/dev/null 2>&1
rc=$?
assert_eq 0 "$rc" "structured review succeeds"
assert_file "$artifact" "success artifact is durable"
assert_file "$repo/reviews/success.d/stdout.json" "raw stdout is durable"
assert_file "$repo/reviews/success.d/stderr.log" "raw stderr is durable"
assert_jq '.status == "completed" and .exit_code == 0 and .terminal_reason == "completed"' "$repo/reviews/success.d/execution.json" "success requires a real terminal reason"
assert_jq '.provider_host == "api.deepseek.com" and .models == ["deepseek-v4-pro"]' "$repo/reviews/success.d/execution.json" "provider host and actual model are recorded safely"
assert_jq '.claude.session_id == "fake-session" and .claude.duration_ms == 1234 and .claude.modelUsage["deepseek-v4-pro"].outputTokens == 20 and .claude.structured_output.verdict == "PASS"' "$repo/reviews/success.d/execution.json" "Claude result metadata is parsed into execution evidence"
assert_jq '.timeout == "30m" and .watchdog_enabled == false' "$repo/reviews/success.d/execution.json" "30 minute timeout and watchdog-off defaults are recorded"
assert_jq '.tool_usage.source == "provider-json" and .tool_usage.tools.Read.count == 3 and .tool_usage.tools.Bash.failed == 1' "$repo/reviews/success.d/execution.json" "tool usage summary is recorded without command details"
if /usr/bin/grep -aEq 'token-value' "$artifact" "$repo/reviews/success.d/execution.json"; then
  fail "provider credentials are not persisted"
else
  pass "provider credentials are not persisted"
fi

repo="$(new_repo safe-mode-default-repo)"
artifact="$repo/reviews/safe-mode-default.md"
run_review capture-args "$repo" "$artifact" 30m >/dev/null 2>&1
rc=$?
assert_eq 0 "$rc" "default safe-mode run succeeds"
assert_jq '.safe_mode == true and .no_tools == false' "$repo/reviews/safe-mode-default.d/execution.json" "safe-mode is on and no-tools off by default"
if /usr/bin/grep -axq -- '--safe-mode' "$state_dir/claude.args"; then
  pass "default run passes --safe-mode to Claude"
else
  fail "default run passes --safe-mode to Claude"
fi

repo="$(new_repo no-safe-mode-repo)"
artifact="$repo/reviews/no-safe-mode.md"
run_review capture-args "$repo" "$artifact" 30m --no-safe-mode >/dev/null 2>&1
rc=$?
assert_eq 0 "$rc" "trusted-repo customization opt-out succeeds"
assert_jq '.safe_mode == false and .no_tools == false' "$repo/reviews/no-safe-mode.d/execution.json" "no-safe-mode opt-out is recorded"
if /usr/bin/grep -axq -- '--safe-mode' "$state_dir/claude.args"; then
  fail "no-safe-mode omits the safe-mode flag"
else
  pass "no-safe-mode omits the safe-mode flag"
fi

repo="$(new_repo no-tools-repo)"
artifact="$repo/reviews/no-tools.md"
run_review capture-args "$repo" "$artifact" 30m --no-tools >/dev/null 2>&1
rc=$?
assert_eq 0 "$rc" "untrusted-repo tools-off mode succeeds"
assert_jq '.no_tools == true and .safe_mode == true' "$repo/reviews/no-tools.d/execution.json" "no-tools mode is recorded with safe-mode still on"
if /usr/bin/grep -axq -- '--tools' "$state_dir/claude.args" && [[ "$(/usr/bin/grep -A1 -x -- '--tools' "$state_dir/claude.args" | tail -n 1)" == "" ]]; then
  pass "no-tools forwards an empty --tools value"
else
  fail "no-tools forwards an empty --tools value"
fi

repo="$(new_repo nonzero-repo)"
artifact="$repo/reviews/nonzero.md"
run_review nonzero "$repo" "$artifact" 30m >/dev/null 2>&1
rc=$?
assert_eq 7 "$rc" "Claude nonzero exit is preserved"
assert_jq '.status == "failed" and .exit_code == 7 and .failure_reason == "claude_exit_nonzero"' "$repo/reviews/nonzero.d/execution.json" "nonzero failure artifact is finalized"

repo="$(new_repo timeout-repo)"
artifact="$repo/reviews/timeout.md"
run_review sleep "$repo" "$artifact" 1s >/dev/null 2>&1
rc=$?
assert_eq 124 "$rc" "timeout exit 124 is preserved"
assert_jq '.status == "timed_out" and .timed_out == true' "$repo/reviews/timeout.d/execution.json" "timeout artifact is finalized"

repo="$(new_repo kill-after-repo)"
artifact="$repo/reviews/kill-after.md"
run_review kill-after-ignore "$repo" "$artifact" 1s >/dev/null 2>&1
rc=$?
assert_eq 137 "$rc" "timeout kill-after exit 137 is preserved"
assert_jq '.status == "timed_out" and .timed_out == true and .failure_reason == "outer_timeout_kill_after"' "$repo/reviews/kill-after.d/execution.json" "kill-after timeout is classified as timed out, not provider failure"

repo="$(new_repo empty-repo)"
artifact="$repo/reviews/empty.md"
run_review empty "$repo" "$artifact" 30m >/dev/null 2>&1
rc=$?
assert_eq 65 "$rc" "empty stdout is rejected"
assert_jq '.status == "failed" and .failure_reason == "empty_stdout"' "$repo/reviews/empty.d/execution.json" "empty output is not treated as completion"

repo="$(new_repo invalid-repo)"
artifact="$repo/reviews/invalid.md"
run_review invalid-json "$repo" "$artifact" 30m >/dev/null 2>&1
rc=$?
assert_eq 65 "$rc" "invalid JSON is rejected"
assert_jq '.failure_reason == "invalid_json"' "$repo/reviews/invalid.d/execution.json" "invalid JSON reason is recorded"

repo="$(new_repo terminal-repo)"
artifact="$repo/reviews/terminal.md"
run_review invalid-terminal "$repo" "$artifact" 30m >/dev/null 2>&1
rc=$?
assert_eq 65 "$rc" "invalid terminal reason is rejected"
assert_jq '.failure_reason == "invalid_terminal_reason"' "$repo/reviews/terminal.d/execution.json" "terminal reason validation is recorded"

repo="$(new_repo schema-repo)"
artifact="$repo/reviews/schema.md"
run_review invalid-structured "$repo" "$artifact" 30m >/dev/null 2>&1
rc=$?
assert_eq 65 "$rc" "invalid structured review is rejected"
assert_jq '.failure_reason == "invalid_structured_output"' "$repo/reviews/schema.d/execution.json" "schema failure is recorded"

repo="$(new_repo fractional-line-repo)"
artifact="$repo/reviews/fractional-line.md"
run_review fractional-line "$repo" "$artifact" 30m >/dev/null 2>&1
rc=$?
assert_eq 65 "$rc" "fractional line number is rejected"
assert_jq '.failure_reason == "invalid_structured_output"' "$repo/reviews/fractional-line.d/execution.json" "integer schema is enforced locally"

repo="$(new_repo negative-line-repo)"
artifact="$repo/reviews/negative-line.md"
run_review negative-line "$repo" "$artifact" 30m >/dev/null 2>&1
rc=$?
assert_eq 65 "$rc" "negative line number is rejected"
assert_jq '.failure_reason == "invalid_structured_output"' "$repo/reviews/negative-line.d/execution.json" "line number must be a positive integer"

repo="$(new_repo extra-field-repo)"
artifact="$repo/reviews/extra-field.md"
run_review extra-field "$repo" "$artifact" 30m >/dev/null 2>&1
rc=$?
assert_eq 65 "$rc" "additional structured fields are rejected"
assert_jq '.failure_reason == "invalid_structured_output"' "$repo/reviews/extra-field.d/execution.json" "additionalProperties false is enforced locally"

repo="$(new_repo is-error-repo)"
artifact="$repo/reviews/is-error.md"
run_review is-error "$repo" "$artifact" 30m >/dev/null 2>&1
rc=$?
assert_eq 65 "$rc" "provider is_error is rejected"
assert_jq '.failure_reason == "claude_reported_error"' "$repo/reviews/is-error.d/execution.json" "provider error state is recorded"

if [[ "$(uname -s)" == "Darwin" ]] && command -v sandbox-exec >/dev/null 2>&1; then
  repo="$(new_repo sandbox-repo)"
  artifact="$repo/reviews/sandbox.md"
  run_review mutate "$repo" "$artifact" 30m >/dev/null 2>&1
  rc=$?
  assert_eq 0 "$rc" "sandboxed fake review still returns structured output"
  # the enforcement canary degrades honestly on hosts where sandbox_apply is
  # denied (nested-sandbox hosts, observed on WorkBuddy): accept either the
  # enforced mode (mutation blocked) or the documented prompt-only degrade
  iso_mode="$(jq -r '.isolation.mode // "?"' "$repo/reviews/sandbox.d/execution.json" 2>/dev/null || echo "?")"
  if [[ "$iso_mode" == "macos-sandbox" ]]; then
    assert_eq baseline "$(cat "$repo/tracked.txt")" "macOS sandbox blocks Bash mutation"
    assert_jq '.isolation.mode == "macos-sandbox" and .mutation.detected == false' "$repo/reviews/sandbox.d/execution.json" "sandbox and mutation evidence are recorded"
  elif [[ "$iso_mode" == "prompt-only" ]]; then
    assert_jq '.isolation.mode == "prompt-only"' "$repo/reviews/sandbox.d/execution.json" "degraded isolation mode is recorded"
    pass "sandbox_apply or liveness canary failed on this host: honest degrade path exercised"
  else
    fail "unresolvable isolation mode in execution.json: $iso_mode"
  fi
fi

repo="$(new_repo signal-repo)"
artifact="$repo/reviews/signal.md"
FAKE_SCENARIO=sleep \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ANTHROPIC_BASE_URL="https://token-value@api.deepseek.com/anthropic" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
  "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1 &
runner_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -f "$repo/reviews/signal.d/execution.json" ]] && break
  sleep 0.1
done
kill -TERM "$runner_pid" 2>/dev/null || true
wait "$runner_pid"
rc=$?
assert_eq 143 "$rc" "external TERM is preserved"
assert_jq '.status == "interrupted" and .termination_signal == "TERM"' "$repo/reviews/signal.d/execution.json" "signal interruption leaves a failure artifact"

repo="$(new_repo hup-repo)"
artifact="$repo/reviews/hup.md"
FAKE_SCENARIO=sleep \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ANTHROPIC_BASE_URL="https://token-value@api.deepseek.com/anthropic" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
  "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1 &
runner_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -f "$repo/reviews/hup.d/execution.json" ]] && break
  sleep 0.1
done
kill -HUP "$runner_pid" 2>/dev/null || true
wait "$runner_pid"
rc=$?
assert_eq 129 "$rc" "external HUP is preserved"
assert_jq '.status == "interrupted" and .termination_signal == "HUP"' "$repo/reviews/hup.d/execution.json" "HUP leaves a failure artifact"

repo="$(new_repo int-repo)"
artifact="$repo/reviews/int.md"
ASK_CLAUDE_TEST_SIGNAL_AFTER_START=INT run_review sleep "$repo" "$artifact" 30m >/dev/null 2>&1
rc=$?
assert_eq 130 "$rc" "external INT is preserved"
assert_jq '.status == "interrupted" and .termination_signal == "INT"' "$repo/reviews/int.d/execution.json" "INT leaves a failure artifact"

repo="$(new_repo descendant-repo)"
artifact="$repo/reviews/descendant.md"
rm -f "$state_dir/child.pid"
run_review descendant "$repo" "$artifact" 1s >/dev/null 2>&1
rc=$?
assert_eq 124 "$rc" "descendant scenario times out"
child_pid="$(cat "$state_dir/child.pid" 2>/dev/null || true)"
sleep 0.2
if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
  fail "review descendants are released"
else
  pass "review descendants are released"
fi
assert_jq '.resources.remaining_pids == []' "$repo/reviews/descendant.d/execution.json" "resource release is recorded"

repo="$(new_repo descendant-orphan-repo)"
artifact="$repo/reviews/orphan.md"
run_review descendant-orphan "$repo" "$artifact" 30m >/dev/null 2>&1
rc=$?
assert_eq 0 "$rc" "orphaned-descendant review completes"
sleep 1
orphan_pid="$(cat "$state_dir/orphan.pid" 2>/dev/null || true)"
if [[ -n "$orphan_pid" ]] && kill -0 "$orphan_pid" 2>/dev/null; then
  fail "reparented descendant is terminated by cleanup"
else
  pass "reparented descendant is terminated by cleanup"
fi
assert_jq '.resources.remaining_pids == [] and .resources.identity_mismatch_pids == []' "$repo/reviews/orphan.d/execution.json" "reparented descendant is released, not reported as a reused pid"

repo="$(new_repo descendant-orphan-killignore-repo)"
artifact="$repo/reviews/orphan-killignore.md"
run_review descendant-orphan-killignore "$repo" "$artifact" 30m >/dev/null 2>&1
rc=$?
assert_eq 0 "$rc" "TERM-ignoring orphan review completes"
sleep 1
orphan2_pid="$(cat "$state_dir/orphan2.pid" 2>/dev/null || true)"
if [[ -n "$orphan2_pid" ]] && kill -0 "$orphan2_pid" 2>/dev/null; then
  fail "TERM-ignoring orphan is stopped by the KILL leg"
else
  pass "TERM-ignoring orphan is stopped by the KILL leg"
fi
assert_jq '.resources.remaining_pids == []' "$repo/reviews/orphan-killignore.d/execution.json" "KILL leg release is recorded from the in-memory tree"

# a failing bounded HEAD probe must fail the snapshot closed instead of
# fabricating a sentinel (and an unborn repo must still read as unborn)
git_fail_revparse="$test_root/git-fail-revparse"
mkdir -p "$git_fail_revparse"
cat >"$git_fail_revparse/git" <<'GITSTUB'
#!/usr/bin/env bash
args=("$@")
if [[ "${args[0]:-}" == "-C" ]]; then
  probe_args=("${args[@]:2}")
else
  probe_args=("${args[@]}")
fi
if [[ "${probe_args[0]:-}" == "rev-parse" && "${probe_args[1]:-}" == "--verify" && "${probe_args[2]:-}" == "-q" && "${probe_args[3]:-}" == "HEAD" ]]; then
  exit 143
fi
exec /usr/bin/git "$@"
GITSTUB
chmod +x "$git_fail_revparse/git"
repo="$(new_repo head-probe-fail-repo)"
artifact="$repo/reviews/head-probe-fail.md"
ASK_CLAUDE_GIT_BIN="$git_fail_revparse/git" FAKE_SCENARIO=success FAKE_STATE_DIR="$state_dir" FAKE_REPO="$repo" ASK_CLAUDE_BIN="$fake_bin/claude"   "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1
rc=$?
assert_eq 70 "$rc" "failing HEAD probe fails the snapshot closed"
assert_jq '.failure_reason == "mutation_snapshot_failure"' "$repo/reviews/head-probe-fail.d/execution.json" "HEAD probe failure is explicit"

mkdir -p "$test_root/unborn-repo-raw"
git -C "$test_root/unborn-repo-raw" init -q
artifact="$test_root/unborn-repo-raw/reviews/unborn.md"
FAKE_SCENARIO=success \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$test_root/unborn-repo-raw" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
  "$runner" --repo "$test_root/unborn-repo-raw" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1
rc=$?
assert_eq 0 "$rc" "unborn repo review completes"
unborn_head="$(jq -r '.mutation.before.head // "MISSING"' "${artifact%.md}.d/execution.json" 2>/dev/null || echo MISSING_FILE)"
if [[ "$unborn_head" == "unborn" ]]; then
  pass "unborn HEAD sentinel is recorded"
else
  fail "unborn HEAD sentinel is recorded (got: $unborn_head)"
fi

repo="$(new_repo pid-identity-repo)"
artifact="$repo/reviews/pid-identity.md"
sleep 30 &
unrelated_pid=$!
FAKE_SCENARIO=delayed-success \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
  "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1 &
runner_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -f "$repo/reviews/pid-identity.d/process-tree.log" ]] && break
  sleep 0.1
done
printf '%s\t%s\n' "$unrelated_pid" 'forged-process-identity' >>"$repo/reviews/pid-identity.d/process-tree.log"
wait "$runner_pid"
rc=$?
assert_eq 0 "$rc" "PID identity scenario review succeeds"
if kill -0 "$unrelated_pid" 2>/dev/null; then
  pass "mismatched PID identity is not killed"
else
  fail "mismatched PID identity is not killed"
fi
kill -TERM "$unrelated_pid" 2>/dev/null || true
wait "$unrelated_pid" 2>/dev/null || true
# release decisions run from the in-memory union (fed by the provider-write-
# denied union file): a forged line in the published evidence log must drive
# neither kills nor mismatch reporting
assert_jq '.resources.identity_mismatch_pids == []' "$repo/reviews/pid-identity.d/execution.json" "forged evidence-log identity does not drive release decisions"

repo="$(new_repo signal-identity-repo)"
artifact="$repo/reviews/signal-identity.md"
sleep 30 &
signal_unrelated_pid=$!
printf '%s\n' "$signal_unrelated_pid" >"$state_dir/signal-unrelated.pid"
signal_fake_bin="$test_root/signal-bin"
mkdir -p "$signal_fake_bin"
cat >"$signal_fake_bin/pgrep" <<'FAKE_PGREP'
#!/usr/bin/env bash
/usr/bin/pgrep "$@" 2>/dev/null || true
if [[ "${1:-}" == "-P" && -n "${2:-}" ]]; then
  parent_command="$(/bin/ps -p "$2" -o comm= 2>/dev/null || true)"
  case "$parent_command" in
    *timeout*) cat "$FAKE_STATE_DIR/signal-unrelated.pid" ;;
  esac
fi
FAKE_PGREP
chmod +x "$signal_fake_bin/pgrep"
FAKE_SCENARIO=sleep \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
PATH="$signal_fake_bin:$PATH" \
  "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1 &
runner_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  /usr/bin/grep -aEq "^${signal_unrelated_pid}[[:space:]]" "$repo/reviews/signal-identity.d/process-tree.log" 2>/dev/null && break
  sleep 0.1
done
/usr/bin/awk -F '\t' -v pid="$signal_unrelated_pid" 'BEGIN {OFS="\t"} $1 == pid {$2="forged-process-identity"} {print}' \
  "$repo/reviews/signal-identity.d/process-tree.log" >"$repo/reviews/signal-identity.d/process-tree.log.tmp"
mv "$repo/reviews/signal-identity.d/process-tree.log.tmp" "$repo/reviews/signal-identity.d/process-tree.log"
kill -TERM "$runner_pid" 2>/dev/null || true
wait "$runner_pid"
rc=$?
assert_eq 143 "$rc" "signal identity scenario preserves TERM"
# the kill decision now runs from the runner's in-memory tree: a forged log
# identity is ignored for release AND never recorded as evidence
if /usr/bin/grep -aq 'forged-process-identity' "${artifact%.md}.d/execution.json"; then
  fail "forged log identity never reaches the execution record"
else
  pass "forged log identity never reaches the execution record"
fi
assert_jq '.process_tracking.degraded == false or (.process_tracking.reasons | index("process_log_path_unsafe") != null)' "${artifact%.md}.d/execution.json" "forged log is at worst a reported degradation"
# the forged log line is ignored for release decisions: the runner either
# released the injected pid under its real sampled identity (memory) or left
# it alive as a mismatch (log-only sample) — what it must never do is leave
# the runner's own tracked tree running
assert_jq '.resources.remaining_pids == [] or ([.resources.remaining_pids[]] | index('"$signal_unrelated_pid"') == null)' "${artifact%.md}.d/execution.json" "signal release never leaves the tracked tree running" 
if [[ -f "$repo/reviews/signal-identity.d/process-tree.log" ]]; then
  while IFS=$'\t' read -r owned_pid _; do
    [[ -n "$owned_pid" ]] && kill -KILL "$owned_pid" 2>/dev/null || true
  done <"$repo/reviews/signal-identity.d/process-tree.log"
fi
kill -KILL "$signal_unrelated_pid" 2>/dev/null || true
wait "$signal_unrelated_pid" 2>/dev/null || true

repo="$(new_repo mutation-repo)"
artifact="$repo/reviews/mutation.md"
FAKE_SCENARIO=delayed-success \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ANTHROPIC_BASE_URL="https://token-value@api.deepseek.com/anthropic" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
  "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1 &
runner_pid=$!
# land the write strictly after the runner's before-snapshot (which runs
# within the first ~200 ms) so the test is not load-sensitive
sleep 1
printf 'concurrent user change\n' >>"$repo/tracked.txt"
wait "$runner_pid"
rc=$?
assert_eq 0 "$rc" "concurrent mutation does not fabricate Claude failure"
assert_jq '.mutation.detected == true and (.mutation.changed_fields | length > 0)' "$repo/reviews/mutation.d/execution.json" "mutation warning includes changed fingerprints"
if /usr/bin/grep -aEq 'Working tree or repository state changed' "$artifact"; then
  pass "mutation warning is visible in artifact"
else
  fail "mutation warning is visible in artifact"
fi

repo="$(new_repo options-repo)"
artifact="$repo/custom/evidence/review.md"
run_review success "$repo" "$artifact" 45m --task "Check pagination contracts" --watchdog --safe-mode --debug --fallback-model sonnet >/dev/null 2>&1
rc=$?
assert_eq 0 "$rc" "stability options succeed"
assert_file "$artifact" "custom gate-evidence artifact path is honored"
assert_file "$repo/custom/evidence/review.d/debug.log" "debug mode preserves a trace sidecar"
assert_jq '.watchdog_enabled == true and .safe_mode == true and .debug_mode == true and .fallback_model == "sonnet" and .timeout == "45m" and .task == "Check pagination contracts"' "$repo/custom/evidence/review.d/execution.json" "stability options and original task are recorded"

repo="$(new_repo debug-tool-summary-repo)"
artifact="$repo/reviews/debug-tool-summary.md"
run_review debug-tools "$repo" "$artifact" 30m --debug >/dev/null 2>&1
rc=$?
assert_eq 0 "$rc" "debug tool summary review succeeds"
assert_jq '.tool_usage.source == "debug-trace" and .tool_usage.tools.Read.count == 1 and .tool_usage.tools.Bash.failed == 1' "$repo/reviews/debug-tool-summary.d/execution.json" "debug trace is collapsed to tool counts"

repo="$(new_repo debug-tool-parse-failure-repo)"
artifact="$repo/reviews/debug-tool-parse-failure.md"
run_review debug-tools-malformed "$repo" "$artifact" 30m --debug >/dev/null 2>&1
rc=$?
assert_eq 65 "$rc" "unparseable debug tool records fail closed"
assert_jq '.status == "failed" and .failure_reason == "tool_usage_parse_failure" and .tool_usage.source == "debug-trace-parse-failed"' "$repo/reviews/debug-tool-parse-failure.d/execution.json" "debug tool parse failure is explicit"

repo="$(new_repo debug-tool-mixed-parse-failure-repo)"
artifact="$repo/reviews/debug-tool-mixed-parse-failure.md"
run_review debug-tools-mixed "$repo" "$artifact" 30m --debug >/dev/null 2>&1
rc=$?
assert_eq 65 "$rc" "partially parsed debug tool records fail closed"
assert_jq '.status == "failed" and .failure_reason == "tool_usage_parse_failure" and .tool_usage.source == "debug-trace-parse-failed"' "$repo/reviews/debug-tool-mixed-parse-failure.d/execution.json" "mixed debug records do not publish incomplete tool counts"

repo="$(new_repo fallback-list-repo)"
artifact="$repo/reviews/fallback-list.md"
run_review capture-args "$repo" "$artifact" 30m --fallback-model 'sonnet,haiku' >/dev/null 2>&1
rc=$?
assert_eq 0 "$rc" "comma-separated fallback model list succeeds"
if /usr/bin/grep -aFxq -- 'sonnet,haiku' "$state_dir/claude.args"; then
  pass "fallback model list is passed as one argument"
else
  fail "fallback model list is passed as one argument"
fi
assert_jq '.fallback_model == "sonnet,haiku"' "$repo/reviews/fallback-list.d/execution.json" "fallback model list is recorded intact"
if /usr/bin/grep -aFxq -- '--dangerously-skip-permissions' "$state_dir/claude.args" && \
   /usr/bin/grep -aFxq -- '--disallowedTools' "$state_dir/claude.args" && \
   /usr/bin/grep -aFxq -- 'Edit,Write,NotebookEdit,WebSearch,WebFetch' "$state_dir/claude.args"; then
  pass "review permission and disallowed tool arguments reach Claude intact"
else
  fail "review permission and disallowed tool arguments reach Claude intact"
fi

repo="$(new_repo subsecond-timeout-repo)"
artifact="$repo/reviews/subsecond-timeout.md"
run_review success "$repo" "$artifact" 0.5s >/dev/null 2>&1
rc=$?
assert_eq 0 "$rc" "positive subsecond timeout is accepted"

repo="$(new_repo artifact-conflict-repo)"
artifact="$repo/reviews/existing.md"
mkdir -p "$(dirname "$artifact")"
printf 'existing evidence\n' >"$artifact"
run_review success "$repo" "$artifact" 30m >/dev/null 2>&1
rc=$?
assert_eq 73 "$rc" "existing artifact path is rejected"
assert_eq "existing evidence" "$(cat "$artifact")" "existing artifact evidence is not overwritten"

repo="$(new_repo artifact-swap-repo)"
artifact="$repo/reviews/swap.md"
swap_target="$test_root/artifact-swap-target.md"
printf 'outside baseline\n' >"$swap_target"
FAKE_SCENARIO=delayed-success \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
ASK_CLAUDE_TEST_FAIL_FINAL_MV=1 \
  "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1 &
runner_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [[ -f "$artifact" ]] && break
  sleep 0.1
done
/bin/unlink "$artifact"
ln -s "$swap_target" "$artifact"
wait "$runner_pid"
rc=$?
assert_eq 74 "$rc" "artifact finalization swap fails closed"
assert_eq "outside baseline" "$(cat "$swap_target")" "artifact fallback never follows replacement symlink"

# a symlink planted at the predictable <artifact>.final.<pid> STAGING path must
# never be followed: the final write is gated on artifact_stage_is_safe
repo="$(new_repo staging-swap-repo)"
mkdir -p "$repo/reviews"
staging_swap_target="$test_root/staging-swap-target.md"
printf 'staging baseline\n' >"$staging_swap_target"
FAKE_SCENARIO=delayed-success \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
  "$runner" --repo "$repo" --scope "git diff" --slug staging --timeout 30m >/dev/null 2>&1 &
runner_pid=$!
staging_artifact=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  staging_artifact="$(find "$repo/.omx/artifacts" -maxdepth 1 -name "claude-staging-*.md" -print -quit 2>/dev/null)"
  [[ -n "$staging_artifact" ]] && break
  sleep 0.1
done
if [[ -n "$staging_artifact" ]]; then
  staging_leaf="${staging_artifact##*/}"
  runner_pid_from_name="${staging_leaf##*-}"
  runner_pid_from_name="${runner_pid_from_name%.md}"
  if [[ "$runner_pid_from_name" =~ ^[0-9]+$ ]]; then
    ln -s "$staging_swap_target" "$staging_artifact.final.$runner_pid_from_name"
  fi
fi
wait "$runner_pid"
rc=$?
assert_eq 74 "$rc" "staging-path swap fails closed"
assert_eq "staging baseline" "$(cat "$staging_swap_target")" "staging write never follows planted symlink"

# a process-tree.log swapped mid-run must degrade tracking fail-closed instead
# of trusting (and killing) unvalidated pids
repo="$(new_repo log-swap-repo)"
artifact="$repo/reviews/log-swap.md"
FAKE_SCENARIO=delayed-success \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
  "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1 &
runner_pid=$!
# wait for the exact sidecar file (not the artifact): the swap must land after
# the runner created it, or the test swaps a not-yet-existing path
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [[ -f "${artifact%.md}.d/process-tree.log" ]] && break
  sleep 0.1
done
log_swap_target="$test_root/log-swap-outside.txt"
printf 'outside log baseline\n' >"$log_swap_target"
/bin/rm -f "${artifact%.md}.d/process-tree.log"
ln -s "$log_swap_target" "${artifact%.md}.d/process-tree.log"
wait "$runner_pid"
rc=$?
assert_eq 70 "$rc" "swapped process log degrades tracking"
assert_jq '.process_tracking.degraded == true and (.process_tracking.reasons | index("process_log_path_unsafe") != null)' "${artifact%.md}.d/execution.json" "swapped log is reported as degraded, not trusted"

# a repo whose gitattributes select a required BROKEN process filter blocks
# or dies inside the runner's own snapshot git calls: the bounded snapshot
# call must fail the run closed (mutation_snapshot_failure/70) instead of
# hanging preflight, and the residual is disclosed in the artifact
repo="$(new_repo required-process-filter-repo)"
artifact="$repo/reviews/required-filter.md"
printf '*.bin filter=fakelfs\n' >"$repo/.gitattributes"
printf 'asset\n' >"$repo/asset.bin"
git -C "$repo" add -A
git -C "$repo" -c filter.fakelfs.process=/bin/true commit -qm "assets before filter is configured"
git -C "$repo" config filter.fakelfs.process /bin/false
git -C "$repo" config filter.fakelfs.required true
printf 'changed asset\n' >>"$repo/asset.bin"
run_review success "$repo" "$artifact" 30m >/dev/null 2>&1
rc=$?
assert_eq 70 "$rc" "broken required process filter fails the snapshot closed"
assert_jq '.status == "failed" and .failure_reason == "mutation_snapshot_failure"' "$repo/reviews/required-filter.d/execution.json" "process filter snapshot failure is explicit"
assert_contains 'Git process filters are configured' "$artifact" "process filter residual is disclosed in the failure artifact"

# a plain rm of process-tree.log mid-run must degrade tracking fail-closed
# (the append must not silently recreate the removed evidence file)
repo="$(new_repo log-rm-repo)"
artifact="$repo/reviews/log-rm.md"
FAKE_SCENARIO=delayed-success \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
  "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1 &
runner_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [[ -f "${artifact%.md}.d/process-tree.log" ]] && break
  sleep 0.1
done
/bin/rm -f "${artifact%.md}.d/process-tree.log"
wait "$runner_pid"
rc=$?
assert_eq 70 "$rc" "removed process log degrades tracking"
assert_jq '.process_tracking.degraded == true and (.process_tracking.reasons | index("process_log_path_unsafe") != null)' "${artifact%.md}.d/execution.json" "removed log is reported as degraded, not clean"

# a foreign-owned or non-0700 shared capture root must fail the run closed:
# the fixed-name root is a squatting target on shared-TMPDIR hosts
repo="$(new_repo shared-root-hardening-repo)"
shared_probe="$test_root/shared-probe"
mkdir -p "$shared_probe" && chmod 777 "$shared_probe"
FAKE_SCENARIO=success \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
  env TMPDIR="$shared_probe" "$runner" --repo "$repo" --scope "git diff" --slug shared --timeout 30m >/dev/null 2>&1
rc=$?
assert_eq 0 "$rc" "same-user shared root run succeeds after tightening"
shared_mode="$(ls -ld "$shared_probe/ask-claude-shared-$(id -u)" 2>/dev/null | cut -c1-10)"
if [[ "$shared_mode" == "drwx------" ]]; then
  pass "shared root mode tightened to 0700"
else
  fail "shared root mode tightened to 0700 (got: ${shared_mode:-missing})"
fi

# hyphenated identifiers containing sk-ant-shaped substrings must NOT
# false-positive the secret ladder (the anthropic_key rule carries the same
# left boundary as the kimi sibling)
repo="$(new_repo boundary-false-positive-repo)"
artifact="$repo/reviews/boundary.md"
run_review success "$repo" "$artifact" 30m --task "Review task-antivirus-quarantine-workflow and risk-anticipation-reporting paths" >/dev/null 2>&1
rc=$?
assert_eq 0 "$rc" "hyphenated sk-ant-shaped identifiers do not false-positive the ladder"
assert_jq '.status == "completed"' "$repo/reviews/boundary.d/execution.json" "boundary false-positive run completes"

# a prompt.txt swapped mid-run must quarantine the run (78) and withhold the
# swapped content from the durable artifact
repo="$(new_repo prompt-swap-repo)"
artifact="$repo/reviews/prompt-swap.md"
prompt_swap_target="$test_root/prompt-swap-outside.txt"
printf 'Authorization: Bearer swapped-prompt-secret-123456\n' >"$prompt_swap_target"
FAKE_SCENARIO=delayed-success \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
  "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1 &
runner_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [[ -f "${artifact%.md}.d/prompt.txt" ]] && break
  sleep 0.1
done
# regular-file swap: the publication-time re-scan detects the secret and
# quarantines the run (78); the swapped bytes never reach the artifact
/bin/rm -f "${artifact%.md}.d/prompt.txt"
printf 'Authorization: Bearer swapped-prompt-secret-123456\n' >"${artifact%.md}.d/prompt.txt"
wait "$runner_pid"
rc=$?
assert_eq 78 "$rc" "swapped prompt.txt quarantines the run"
assert_jq '.status == "failed" and .failure_reason == "sensitive_output_detected" and (.secret_scan.sources | index("prompt-final") != null)' "${artifact%.md}.d/execution.json" "swapped prompt detection is recorded"
if /usr/bin/grep -aq 'swapped-prompt-secret-123456' "$artifact"; then
  fail "swapped prompt content never reaches the artifact"
else
  pass "swapped prompt content never reaches the artifact"
fi

# a stdout.json swapped mid-run must neither leak the swapped target's content
# into the artifact nor let it drive the Verdict line
repo="$(new_repo stdout-swap-repo)"
artifact="$repo/reviews/stdout-swap.md"
stdout_swap_target="$test_root/stdout-swap-outside.json"
printf '{"structured_output":{"verdict":"PASS","findings":[],"caveats":["injected caveat from swapped file"],"next_steps":[]},"terminal_reason":"completed","is_error":false}\n' >"$stdout_swap_target"
FAKE_SCENARIO=delayed-success \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
  "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1 &
runner_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [[ -f "${artifact%.md}.d/stdout.json" ]] && break
  sleep 0.1
done
/bin/rm -f "${artifact%.md}.d/stdout.json"
ln -s "$stdout_swap_target" "${artifact%.md}.d/stdout.json"
wait "$runner_pid"
rc=$?
assert_eq 74 "$rc" "swapped stdout.json fails publication closed"
assert_eq "failed path validation" "$(grep -ac 'failed path validation' "$artifact" >/dev/null && printf 'failed path validation')" "artifact marks withheld raw output"
if /usr/bin/grep -aq 'injected caveat from swapped file' "$artifact" "${artifact%.md}.d/execution.json"; then
  fail "swapped stdout content never reaches artifact or record"
else
  pass "swapped stdout content never reaches artifact or record"
fi
assert_jq '.claude.structured_output == null and .secret_scan.scan_failed == true' "${artifact%.md}.d/execution.json" "publication failure marks the scan failed and clears provider payloads"

preflight_mktemp_bin="$test_root/preflight-mktemp-bin"
mkdir -p "$preflight_mktemp_bin"
cat >"$preflight_mktemp_bin/mktemp" <<'PREFLIGHT_MKTEMP'
#!/usr/bin/env bash
case "$*" in
  *ask-claude-prompt*)
    case "${ASK_CLAUDE_TEST_PREFLIGHT_MUTATION:-}" in
      sidecar-swap)
        /bin/mv "$ASK_CLAUDE_TEST_SIDECAR" "$ASK_CLAUDE_TEST_SIDECAR_ORIGINAL"
        ln -s "$ASK_CLAUDE_TEST_OUTSIDE_SIDECAR" "$ASK_CLAUDE_TEST_SIDECAR"
        ;;
      execution-directory)
        mkdir "$ASK_CLAUDE_TEST_EXECUTION_FILE"
        ;;
      artifact-swap)
        /bin/unlink "$ASK_CLAUDE_TEST_ARTIFACT"
        ln -s "$ASK_CLAUDE_TEST_ARTIFACT_TARGET" "$ASK_CLAUDE_TEST_ARTIFACT"
        ;;
    esac
    exit 1
    ;;
  *) exec /usr/bin/mktemp "$@" ;;
esac
PREFLIGHT_MKTEMP
chmod +x "$preflight_mktemp_bin/mktemp"

repo="$(new_repo sidecar-preflight-swap-repo)"
artifact="$repo/reviews/sidecar-preflight-swap.md"
outside_sidecar="$test_root/sidecar-preflight-outside"
mkdir -p "$outside_sidecar"
outside_cleanup_temp="$outside_sidecar/execution.json.tmp"
printf 'outside cleanup baseline\n' >"$outside_cleanup_temp"
sidecar_path="${artifact%.md}.d"
PATH="$preflight_mktemp_bin:$PATH" \
ASK_CLAUDE_TEST_PREFLIGHT_MUTATION=sidecar-swap \
ASK_CLAUDE_TEST_SIDECAR="$sidecar_path" \
ASK_CLAUDE_TEST_SIDECAR_ORIGINAL="$test_root/sidecar-preflight-original" \
ASK_CLAUDE_TEST_OUTSIDE_SIDECAR="$outside_sidecar" \
FAKE_SCENARIO=success FAKE_STATE_DIR="$state_dir" FAKE_REPO="$repo" ASK_CLAUDE_BIN="$fake_bin/claude" \
  "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1
rc=$?
assert_eq 74 "$rc" "preflight sidecar swap fails closed"
assert_eq "outside cleanup baseline" "$(cat "$outside_cleanup_temp")" "sidecar swap cleanup never deletes outside staging files"
if find "$outside_sidecar" -type f ! -name execution.json.tmp -print -quit | grep -q .; then
  fail "sidecar swap never writes outside the repository"
else
  pass "sidecar swap never writes outside the repository"
fi

repo="$(new_repo normal-exit-sidecar-cleanup-swap-repo)"
artifact="$repo/reviews/normal-exit-sidecar-cleanup-swap.md"
outside_sidecar="$test_root/normal-exit-sidecar-cleanup-outside"
normal_exit_original="$test_root/normal-exit-sidecar-cleanup-original"
normal_exit_mv_bin="$test_root/normal-exit-sidecar-cleanup-mv-bin"
mkdir -p "$outside_sidecar"
mkdir -p "$normal_exit_mv_bin"
outside_cleanup_temp="$outside_sidecar/execution.json.tmp"
printf 'normal exit cleanup baseline\n' >"$outside_cleanup_temp"
cat >"$normal_exit_mv_bin/mv" <<'NORMAL_EXIT_MV'
#!/usr/bin/env bash
set -u

if [[ "${ASK_CLAUDE_TEST_SWAP_AFTER_FINAL_ARTIFACT:-}" == "1" && "${1:-}" == *.final.* && "${2:-}" == *.md ]]; then
  /bin/mv "$@"
  /bin/mv "$ASK_CLAUDE_TEST_SIDECAR" "$ASK_CLAUDE_TEST_SIDECAR_ORIGINAL"
  ln -s "$ASK_CLAUDE_TEST_OUTSIDE_SIDECAR" "$ASK_CLAUDE_TEST_SIDECAR"
  exit 0
fi

exec /bin/mv "$@"
NORMAL_EXIT_MV
chmod +x "$normal_exit_mv_bin/mv"
sidecar_path="${artifact%.md}.d"
PATH="$normal_exit_mv_bin:$PATH" \
ASK_CLAUDE_TEST_SWAP_AFTER_FINAL_ARTIFACT=1 \
ASK_CLAUDE_TEST_SIDECAR="$sidecar_path" \
ASK_CLAUDE_TEST_SIDECAR_ORIGINAL="$normal_exit_original" \
ASK_CLAUDE_TEST_OUTSIDE_SIDECAR="$outside_sidecar" \
FAKE_SCENARIO=success FAKE_STATE_DIR="$state_dir" FAKE_REPO="$repo" ASK_CLAUDE_BIN="$fake_bin/claude" \
  "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1 &
runner_pid=$!
wait "$runner_pid"
rc=$?
assert_eq 0 "$rc" "normal-exit sidecar cleanup swap preserves successful review"
assert_jq '.status == "completed" and .runner_exit_code == 0 and .terminal_reason == "completed"' "$normal_exit_original/execution.json" "normal-exit sidecar original contains completed evidence"
assert_eq "normal exit cleanup baseline" "$(cat "$outside_cleanup_temp")" "normal-exit cleanup never deletes outside staging files"
if find "$outside_sidecar" -type f ! -name execution.json.tmp -print -quit | grep -q .; then
  fail "normal-exit cleanup never writes outside the repository"
else
  pass "normal-exit cleanup never writes outside the repository"
fi

repo="$(new_repo preflight-execution-directory-repo)"
artifact="$repo/reviews/preflight-execution-directory.md"
sidecar_path="${artifact%.md}.d"
PATH="$preflight_mktemp_bin:$PATH" \
ASK_CLAUDE_TEST_PREFLIGHT_MUTATION=execution-directory \
ASK_CLAUDE_TEST_EXECUTION_FILE="$sidecar_path/execution.json" \
FAKE_SCENARIO=success FAKE_STATE_DIR="$state_dir" FAKE_REPO="$repo" ASK_CLAUDE_BIN="$fake_bin/claude" \
  "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1
rc=$?
assert_eq 74 "$rc" "preflight execution sidecar directory fails closed"
[[ -d "$sidecar_path/execution.json" ]] && pass "execution sidecar directory is not replaced" || fail "execution sidecar directory is not replaced"
if find "$sidecar_path/execution.json" -mindepth 1 -print -quit | grep -q .; then
  fail "preflight execution JSON is not moved into a directory"
else
  pass "preflight execution JSON is not moved into a directory"
fi

repo="$(new_repo preflight-artifact-swap-repo)"
artifact="$repo/reviews/preflight-artifact-swap.md"
artifact_swap_target="$test_root/preflight-artifact-swap-target.md"
printf 'outside baseline\n' >"$artifact_swap_target"
PATH="$preflight_mktemp_bin:$PATH" \
ASK_CLAUDE_TEST_PREFLIGHT_MUTATION=artifact-swap \
ASK_CLAUDE_TEST_ARTIFACT="$artifact" \
ASK_CLAUDE_TEST_ARTIFACT_TARGET="$artifact_swap_target" \
FAKE_SCENARIO=success FAKE_STATE_DIR="$state_dir" FAKE_REPO="$repo" ASK_CLAUDE_BIN="$fake_bin/claude" \
  "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1
rc=$?
assert_eq 74 "$rc" "preflight artifact swap fails closed"
assert_eq "outside baseline" "$(cat "$artifact_swap_target")" "preflight artifact swap never follows replacement symlink"
assert_jq '.failure_reason == "artifact_write_failure" and .preflight_failure_reason == "prompt_temp_creation_failure"' "${artifact%.md}.d/execution.json" "preflight artifact publication failure is recorded"

repo="$(new_repo artifact-outside-repo)"
artifact="$test_root/outside-review.md"
run_review success "$repo" "$artifact" 30m >/dev/null 2>&1
rc=$?
assert_eq 64 "$rc" "artifact outside repository is rejected"
[[ ! -e "$artifact" ]] && pass "outside artifact is not created" || fail "outside artifact is not created"

non_repo="$test_root/not-a-git-repository"
mkdir -p "$non_repo"
FAKE_SCENARIO=success FAKE_STATE_DIR="$state_dir" FAKE_REPO="$non_repo" ASK_CLAUDE_BIN="$fake_bin/claude" \
  "$runner" --repo "$non_repo" --scope "git diff" --artifact "$non_repo/review.md" --timeout 30m >/dev/null 2>&1
rc=$?
assert_eq 66 "$rc" "non-Git repository is rejected"
[[ ! -e "$non_repo/review.md" ]] && pass "non-Git repository creates no artifact" || fail "non-Git repository creates no artifact"

missing_repo="$test_root/missing-repository"
FAKE_SCENARIO=success FAKE_STATE_DIR="$state_dir" FAKE_REPO="$missing_repo" ASK_CLAUDE_BIN="$fake_bin/claude" \
  "$runner" --repo "$missing_repo" --scope "git diff" --artifact "$missing_repo/review.md" --timeout 30m >/dev/null 2>&1
rc=$?
assert_eq 66 "$rc" "missing repository is rejected"

repo="$(new_repo artifact-git-dir-repo)"
artifact="$repo/.git/ask-claude-review.md"
run_review success "$repo" "$artifact" 30m >/dev/null 2>&1
rc=$?
assert_eq 64 "$rc" "artifact under Git directory is rejected"
[[ ! -e "$artifact" ]] && pass "Git artifact is not created" || fail "Git artifact is not created"

repo="$(new_repo artifact-symlink-repo)"
mkdir -p "$test_root/symlink-target"
ln -s "$test_root/symlink-target" "$repo/reviews-link"
artifact="$repo/reviews-link/escaped.md"
run_review success "$repo" "$artifact" 30m >/dev/null 2>&1
rc=$?
assert_eq 64 "$rc" "artifact symlink escape is rejected"
[[ ! -e "$test_root/symlink-target/escaped.md" ]] && pass "symlink escape artifact is not created" || fail "symlink escape artifact is not created"

for unsafe_artifact in 'star-*.md' 'question-?.md' 'bracket-[x].md'; do
  repo="$(new_repo "artifact-pathspec-${unsafe_artifact//[^A-Za-z0-9]/}")"
  artifact="$repo/reviews/$unsafe_artifact"
  run_review success "$repo" "$artifact" 30m >/dev/null 2>&1
  rc=$?
  assert_eq 64 "$rc" "Git pathspec metacharacters are rejected: $unsafe_artifact"
  [[ ! -e "$artifact" ]] && pass "unsafe artifact is not created: $unsafe_artifact" || fail "unsafe artifact is not created: $unsafe_artifact"
done

repo="$(new_repo artifact-sibling-mutation-repo)"
mkdir -p "$repo/reviews"
printf 'baseline sibling\n' >"$repo/reviews/sibling.md"
git -C "$repo" add reviews/sibling.md
git -C "$repo" commit -qm 'add review sibling'
artifact="$repo/reviews/safe.md"
FAKE_SCENARIO=delayed-success \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
  "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1 &
runner_pid=$!
# land strictly after the before-snapshot (~first 200 ms) so the test is not
# load-sensitive
sleep 1
printf 'concurrent sibling mutation\n' >>"$repo/reviews/sibling.md"
wait "$runner_pid"
rc=$?
assert_eq 0 "$rc" "sibling mutation review still completes"
assert_jq '.mutation.detected == true and (.mutation.changed_fields | index("worktree_fingerprint") != null)' "$repo/reviews/safe.d/execution.json" "sibling mutation is not excluded"

repo="$(new_repo slug-path-repo)"
FAKE_SCENARIO=success \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
  "$runner" --repo "$repo" --scope "git diff" --slug "bad/slug" --timeout 30m >/dev/null 2>&1
rc=$?
assert_eq 64 "$rc" "slug path separator is rejected"

repo="$(new_repo artifact-dangling-symlink-repo)"
mkdir -p "$repo/reviews"
artifact="$repo/reviews/dangling.md"
dangling_target="$test_root/dangling-symlink-target"
rm -f "$dangling_target"
ln -s "$dangling_target" "$artifact"
FAKE_SCENARIO=success \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
  "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1
rc=$?
assert_eq 73 "$rc" "dangling symlink artifact is rejected"
[[ ! -e "$dangling_target" && -L "$artifact" ]] && pass "dangling symlink target is never created" || fail "dangling symlink target is never created"
/bin/unlink "$artifact"

repo="$(new_repo hash-missing-repo)"
artifact="$repo/reviews/hash-missing.md"
FAKE_SCENARIO=success \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
ASK_CLAUDE_HASH_BIN="$test_root/missing-hash-tool" \
  "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1
rc=$?
assert_eq 69 "$rc" "missing hash tool fails closed"
assert_file "$artifact" "missing hash leaves terminal artifact"
assert_jq '.status == "failed" and .failure_reason == "dependency_hash_missing" and .phase == "preflight"' "$repo/reviews/hash-missing.d/execution.json" "missing hash failure is finalized"

repo="$(new_repo preflight-metadata-secret-repo)"
artifact="$repo/reviews/preflight-metadata-secret.md"
FAKE_SCENARIO=success \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
ASK_CLAUDE_HASH_BIN="$test_root/missing-hash-tool" \
  "$runner" --repo "$repo" \
    --scope "Review password=preflight-scope-secret-123456" \
    --task "Check token=preflight-task-secret-123456" \
    --artifact "$artifact" --timeout 30m >/dev/null 2>&1
rc=$?
assert_eq 69 "$rc" "preflight dependency failure is preserved"
for published_path in "$artifact" "$repo/reviews/preflight-metadata-secret.d/execution.json"; do
  assert_not_contains 'preflight-scope-secret-123456|preflight-task-secret-123456' "$published_path" "pre-scan caller metadata is absent from $(basename "$published_path")"
done

repo="$(new_repo jq-missing-repo)"
artifact="$repo/reviews/jq-missing.md"
FAKE_SCENARIO=success \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
ASK_CLAUDE_JQ_BIN="$test_root/missing-jq-tool" \
  "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1
rc=$?
assert_eq 69 "$rc" "missing jq fails closed"
assert_file "$artifact" "missing jq leaves terminal artifact"
assert_jq '.status == "failed" and .failure_reason == "dependency_jq_missing"' "$repo/reviews/jq-missing.d/execution.json" "missing jq uses minimal terminal evidence"

repo="$(new_repo pgrep-missing-repo)"
artifact="$repo/reviews/pgrep-missing.md"
FAKE_SCENARIO=success \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
ASK_CLAUDE_PGREP_BIN="$test_root/missing-pgrep-tool" \
  "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1
rc=$?
assert_eq 69 "$rc" "missing pgrep fails closed"
assert_jq '.failure_reason == "dependency_pgrep_missing"' "$repo/reviews/pgrep-missing.d/execution.json" "process tracking dependency failure is finalized"

repo="$(new_repo pgrep-broken-repo)"
artifact="$repo/reviews/pgrep-broken.md"
broken_pgrep="$test_root/broken-pgrep"
cat >"$broken_pgrep" <<'BROKEN_PGREP'
#!/usr/bin/env bash
exit 1
BROKEN_PGREP
chmod +x "$broken_pgrep"
FAKE_SCENARIO=success \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
ASK_CLAUDE_PGREP_BIN="$broken_pgrep" \
  "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1
rc=$?
assert_eq 69 "$rc" "broken pgrep fails closed"
assert_jq '.failure_reason == "dependency_pgrep_unusable"' "$repo/reviews/pgrep-broken.d/execution.json" "broken pgrep usability failure is finalized"

repo="$(new_repo pgrep-runtime-failure-repo)"
artifact="$repo/reviews/pgrep-runtime-failure.md"
runtime_pgrep="$test_root/runtime-pgrep"
runtime_pgrep_count="$state_dir/runtime-pgrep.count"
real_pgrep="$(command -v pgrep)"
cat >"$runtime_pgrep" <<'RUNTIME_PGREP'
#!/usr/bin/env bash
count="$(cat "$RUNTIME_PGREP_COUNT" 2>/dev/null || printf '0')"
count=$((count + 1))
printf '%s\n' "$count" >"$RUNTIME_PGREP_COUNT"
if [[ "$count" -eq 1 ]]; then
  exec "$REAL_PGREP" "$@"
fi
exit 2
RUNTIME_PGREP
chmod +x "$runtime_pgrep"
RUNTIME_PGREP_COUNT="$runtime_pgrep_count" \
REAL_PGREP="$real_pgrep" \
FAKE_SCENARIO=success \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
ASK_CLAUDE_PGREP_BIN="$runtime_pgrep" \
  "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1
rc=$?
assert_eq 70 "$rc" "runtime pgrep failure makes review uncertain"
assert_jq '.status == "failed" and .failure_reason == "process_tracking_degraded" and .process_tracking.degraded == true and (.process_tracking.reasons | index("pgrep_runtime_failure") != null)' "$repo/reviews/pgrep-runtime-failure.d/execution.json" "runtime pgrep degradation is explicit"

repo="$(new_repo ps-runtime-failure-repo)"
artifact="$repo/reviews/ps-runtime-failure.md"
runtime_ps="$test_root/runtime-ps"
runtime_ps_count="$state_dir/runtime-ps.count"
real_ps="$(command -v ps)"
cat >"$runtime_ps" <<'RUNTIME_PS'
#!/usr/bin/env bash
count="$(cat "$RUNTIME_PS_COUNT" 2>/dev/null || printf '0')"
count=$((count + 1))
printf '%s\n' "$count" >"$RUNTIME_PS_COUNT"
if [[ "$count" -le 2 ]]; then
  exec "$REAL_PS" "$@"
fi
exit 2
RUNTIME_PS
chmod +x "$runtime_ps"
RUNTIME_PS_COUNT="$runtime_ps_count" \
REAL_PS="$real_ps" \
FAKE_SCENARIO=success \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
ASK_CLAUDE_PS_BIN="$runtime_ps" \
  "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1
rc=$?
assert_eq 70 "$rc" "runtime ps failure makes review uncertain"
assert_jq '.status == "failed" and .failure_reason == "process_tracking_degraded" and .process_tracking.degraded == true and (.process_tracking.reasons | index("ps_identity_runtime_failure") != null)' "$repo/reviews/ps-runtime-failure.d/execution.json" "runtime ps degradation is explicit"

repo="$(new_repo ps-runtime-process-gone-repo)"
artifact="$repo/reviews/ps-runtime-process-gone.md"
runtime_ps_process_gone="$test_root/runtime-ps-process-gone"
runtime_ps_process_gone_count="$state_dir/runtime-ps-process-gone.count"
cat >"$runtime_ps_process_gone" <<'RUNTIME_PS_PROCESS_GONE'
#!/usr/bin/env bash
count="$(cat "$RUNTIME_PS_PROCESS_GONE_COUNT" 2>/dev/null || printf '0')"
count=$((count + 1))
printf '%s\n' "$count" >"$RUNTIME_PS_PROCESS_GONE_COUNT"
if [[ "$count" -le 2 ]]; then
  exec "$REAL_PS" "$@"
fi
exit 1
RUNTIME_PS_PROCESS_GONE
chmod +x "$runtime_ps_process_gone"
RUNTIME_PS_PROCESS_GONE_COUNT="$runtime_ps_process_gone_count" \
REAL_PS="$real_ps" \
FAKE_SCENARIO=success \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
ASK_CLAUDE_PS_BIN="$runtime_ps_process_gone" \
  "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1
rc=$?
assert_eq 0 "$rc" "process-gone ps exit does not degrade a successful review"
assert_jq '.process_tracking.degraded == false and .process_tracking.reasons == []' "$repo/reviews/ps-runtime-process-gone.d/execution.json" "process-gone ps exit is not reported as tool failure"

repo="$(new_repo git-override-repo)"
artifact="$repo/reviews/git-override.md"
real_git="$(command -v git)"
fake_git_dir="$test_root/fake-git"
mkdir -p "$fake_git_dir"
cat >"$fake_git_dir/git" <<'BROKEN_GIT'
#!/usr/bin/env bash
printf 'unexpected PATH git invocation\n' >&2
exit 1
BROKEN_GIT
chmod +x "$fake_git_dir/git"
PATH="$fake_git_dir:$PATH" \
FAKE_SCENARIO=success \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
ASK_CLAUDE_GIT_BIN="$real_git" \
  "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1
rc=$?
assert_eq 0 "$rc" "explicit Git override is used for snapshots"

repo="$(new_repo secret-repo)"
artifact="$repo/reviews/secret.md"
run_review secret-output "$repo" "$artifact" 30m >/dev/null 2>&1
rc=$?
assert_eq 78 "$rc" "sensitive raw output blocks review publication"
assert_jq '.status == "failed" and .failure_reason == "sensitive_output_detected" and .secret_scan.detected == true and (.secret_scan.rule_ids | index("authorization_bearer") != null) and .secret_scan.match_count >= 1' "$repo/reviews/secret.d/execution.json" "secret detection records rule metadata without values"
assert_not_contains 'review-secret-value-123456' "$artifact" "secret is absent from markdown artifact"
assert_not_contains 'review-secret-value-123456' "$repo/reviews/secret.d/stdout.json" "secret is absent from durable raw sidecar"
assert_not_contains 'review-secret-value-123456' "$repo/reviews/secret.d/execution.json" "secret is absent from parsed execution evidence"

repo="$(new_repo secret-match-then-scan-failure-repo)"
artifact="$repo/reviews/secret-match-then-scan-failure.md"
partial_scan_grep="$test_root/partial-scan-grep"
cat >"$partial_scan_grep" <<'PARTIAL_SCAN_GREP'
#!/usr/bin/env bash
case "$*" in
  *'api[_-]?key'*|*'access[_-]?token'*|*'refresh[_-]?token'*|*'client[_-]?secret'*|*'password'*)
    case "${4:-}" in
      *ask-claude-stdout.*|*ask-claude-debug.*) exit 2 ;;
      '') [[ "${FAKE_SCENARIO:-}" == scan-failure ]] && exit 2 || exec /usr/bin/grep "$@" ;;
      *) exec /usr/bin/grep "$@" ;;
    esac
    ;;
  *) exec /usr/bin/grep "$@" ;;
esac
PARTIAL_SCAN_GREP
chmod +x "$partial_scan_grep"
FAKE_SCENARIO=scan-failure \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
ASK_CLAUDE_GREP_BIN="$partial_scan_grep" \
  "$runner" \
    --repo "$repo" \
    --scope "git diff" \
    --task "Check Authorization: Bearer partial-scan-secret-123456" \
    --artifact "$artifact" \
    --timeout 30m >/dev/null 2>&1
rc=$?
assert_eq 78 "$rc" "matched sensitive input plus scan failure fails closed"
assert_jq '.status == "failed" and .failure_reason == "sensitive_input_scan_failure" and .secret_scan.detected == true and .secret_scan.scan_failed == true and (.secret_scan.rule_ids | index("authorization_bearer") != null)' "$repo/reviews/secret-match-then-scan-failure.d/execution.json" "match and scan failure are both retained"

repo="$(new_repo output-match-then-scan-failure-repo)"
artifact="$repo/reviews/output-match-then-scan-failure.md"
ASK_CLAUDE_GREP_BIN="$partial_scan_grep" \
FAKE_SCENARIO=secret-output \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ANTHROPIC_BASE_URL="https://token-value@api.deepseek.com/anthropic" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
  "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1
rc=$?
assert_eq 78 "$rc" "matched sensitive output plus scan failure fails closed"
assert_jq '.status == "failed" and .failure_reason == "secret_scan_failure" and .secret_scan.detected == true and .secret_scan.scan_failed == true and (.secret_scan.sources | index("stdout") != null) and (.secret_scan.sources | index("stdout-scan-error") != null) and (.secret_scan.rule_ids | index("authorization_bearer") != null)' "$repo/reviews/output-match-then-scan-failure.d/execution.json" "output match and scan failure are both retained"

repo="$(new_repo metadata-secret-repo)"
artifact="$repo/reviews/metadata-secret.md"
FAKE_SCENARIO=success \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
  "$runner" \
    --repo "$repo" \
    --scope "Review password=scope-secret-value-123456" \
    --task "Check Authorization: Bearer task-secret-value-123456" \
    --artifact "$artifact" \
    --timeout 30m >/dev/null 2>&1
rc=$?
assert_eq 78 "$rc" "sensitive caller metadata blocks review launch"
assert_jq '.status == "failed" and .failure_reason == "sensitive_input_detected" and .secret_scan.detected == true and (.secret_scan.sources | index("task") != null) and (.secret_scan.sources | index("scope") != null) and (.secret_scan.sources | index("prompt") != null)' "$repo/reviews/metadata-secret.d/execution.json" "sensitive caller metadata is recorded without its value"
assert_jq '.task == "[REDACTED: sensitive caller metadata]" and .scope == "[REDACTED: sensitive caller metadata]"' "$repo/reviews/metadata-secret.d/execution.json" "preflight evidence accurately identifies scanned sensitive metadata"
assert_contains 'REDACTED: sensitive caller metadata' "$artifact" "metadata-secret artifact accurately identifies scanned sensitive metadata"
for published_path in "$artifact" "$repo/reviews/metadata-secret.d/prompt.txt" "$repo/reviews/metadata-secret.d/execution.json"; do
  assert_not_contains 'scope-secret-value-123456|task-secret-value-123456' "$published_path" "caller secret is absent from $(basename "$published_path")"
done

repo="$(new_repo debug-secret-repo)"
artifact="$repo/reviews/debug-secret.md"
run_review debug-tools-secret "$repo" "$artifact" 30m --debug >/dev/null 2>&1
rc=$?
assert_eq 78 "$rc" "sensitive debug trace blocks review publication"
assert_jq '.status == "failed" and .failure_reason == "sensitive_output_detected" and (.secret_scan.sources | index("debug") != null)' "$repo/reviews/debug-secret.d/execution.json" "debug-only secret detection is recorded"
for published_path in "$artifact" "$repo/reviews/debug-secret.d/stdout.json" "$repo/reviews/debug-secret.d/stderr.log" "$repo/reviews/debug-secret.d/debug.log" "$repo/reviews/debug-secret.d/execution.json"; do
  assert_not_contains 'debug-secret-value-123456' "$published_path" "debug secret is absent from $(basename "$published_path")"
done

repo="$(new_repo debug-match-then-scan-failure-repo)"
artifact="$repo/reviews/debug-match-then-scan-failure.md"
ASK_CLAUDE_GREP_BIN="$partial_scan_grep" \
  run_review debug-tools-secret "$repo" "$artifact" 30m --debug >/dev/null 2>&1
rc=$?
assert_eq 78 "$rc" "matched debug output plus scan failure fails closed"
assert_jq '.status == "failed" and .failure_reason == "secret_scan_failure" and .secret_scan.detected == true and .secret_scan.scan_failed == true and (.secret_scan.sources | index("debug") != null) and (.secret_scan.sources | index("debug-scan-error") != null) and (.secret_scan.rule_ids | index("authorization_bearer") != null)' "$repo/reviews/debug-match-then-scan-failure.d/execution.json" "debug match and scan failure are both retained"

repo="$(new_repo early-signal-repo)"
artifact="$repo/reviews/early-signal.md"
slow_bin="$test_root/slow-bin"
mkdir -p "$slow_bin"
cat >"$slow_bin/shasum" <<'SLOW_HASH'
#!/usr/bin/env bash
sleep 5
exec /usr/bin/shasum "$@"
SLOW_HASH
chmod +x "$slow_bin/shasum"
PATH="$slow_bin:$PATH" \
FAKE_SCENARIO=sleep \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
  "$runner" --repo "$repo" --scope "git diff" --artifact "$artifact" --timeout 30m >/dev/null 2>&1 &
runner_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [[ -f "$artifact" ]] && break
  sleep 0.1
done
kill -TERM "$runner_pid" 2>/dev/null || true
wait "$runner_pid"
rc=$?
assert_eq 143 "$rc" "preflight TERM exit is preserved"
assert_jq '.status == "interrupted" and .termination_signal == "TERM" and .phase == "preflight"' "$repo/reviews/early-signal.d/execution.json" "preflight signal finalizes failure evidence"

repo="$(new_repo early-signal-metadata-secret-repo)"
artifact="$repo/reviews/early-signal-metadata-secret.md"
PATH="$slow_bin:$PATH" \
FAKE_SCENARIO=sleep \
FAKE_STATE_DIR="$state_dir" \
FAKE_REPO="$repo" \
ASK_CLAUDE_BIN="$fake_bin/claude" \
  "$runner" --repo "$repo" \
    --scope "Review password=early-scope-secret-123456" \
    --task "Check token=early-task-secret-123456" \
    --artifact "$artifact" --timeout 30m >/dev/null 2>&1 &
runner_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [[ -f "$artifact" ]] && break
  sleep 0.1
done
kill -TERM "$runner_pid" 2>/dev/null || true
wait "$runner_pid"
rc=$?
# two valid terminal outcomes: TERM wins the race into the pre-scan window
# (143, metadata placeholders) or the secret scan fires first (78,
# sensitive_input_detected) — both must keep the secret values out
case "$rc" in
  143|78) pass "pre-scan metadata signal exit is preserved (got $rc)" ;;
  *) fail "pre-scan metadata signal exit is preserved (got $rc)" ;;
esac
for published_path in "$artifact" "$repo/reviews/early-signal-metadata-secret.d/execution.json"; do
  assert_not_contains 'early-scope-secret-123456|early-task-secret-123456' "$published_path" "pre-scan signal metadata is absent from $(basename "$published_path")"
done

repo="$(new_repo spawn-race-repo)"
artifact="$repo/reviews/spawn-race.md"
ASK_CLAUDE_TEST_SIGNAL_AFTER_SPAWN=TERM run_review sleep "$repo" "$artifact" 30m >/dev/null 2>&1
rc=$?
assert_eq 143 "$rc" "signal during PID registration is preserved"
assert_jq '.status == "interrupted" and .termination_signal == "TERM" and .resources.remaining_pids == []' "$repo/reviews/spawn-race.d/execution.json" "spawn race leaves no tracked provider process"

repo="$(new_repo invalid-timeout-repo)"
artifact="$repo/reviews/invalid-timeout.md"
run_review success "$repo" "$artifact" invalid >/dev/null 2>&1
rc=$?
assert_eq 64 "$rc" "invalid timeout is rejected before artifact reservation"
[[ ! -e "$artifact" ]] && pass "invalid timeout creates no artifact" || fail "invalid timeout creates no artifact"

repo="$(new_repo debug-temp-failure-repo)"
artifact="$repo/reviews/debug-temp-failure.md"
debug_mktemp_bin="$test_root/debug-mktemp-bin"
mkdir -p "$debug_mktemp_bin"
cat >"$debug_mktemp_bin/mktemp" <<'FAKE_MKTEMP'
#!/usr/bin/env bash
case "$*" in
  *ask-claude-debug*) exit 1 ;;
  *) exec /usr/bin/mktemp "$@" ;;
esac
FAKE_MKTEMP
chmod +x "$debug_mktemp_bin/mktemp"
PATH="$debug_mktemp_bin:$PATH" run_review success "$repo" "$artifact" 30m --debug >/dev/null 2>&1
rc=$?
assert_eq 73 "$rc" "debug temp creation failure is surfaced"
assert_jq '.status == "failed" and .failure_reason == "debug_temp_creation_failure"' "$repo/reviews/debug-temp-failure.d/execution.json" "debug temp failure replaces RUNNING artifact"

repo="$(new_repo artifact-write-repo)"
artifact="$repo/reviews/artifact-write.md"
ASK_CLAUDE_TEST_FAIL_FINAL_MV=1 run_review success "$repo" "$artifact" 30m >/dev/null 2>&1
rc=$?
assert_eq 74 "$rc" "artifact finalization failure is surfaced"
assert_jq '.status == "failed" and .failure_reason == "artifact_write_failure"' "$repo/reviews/artifact-write.d/execution.json" "artifact write failure is recorded"
if find "$repo/reviews" -maxdepth 1 -type f \( -name '*.partial.*' -o -name '*.final.*' \) | grep -q .; then
  fail "artifact staging files are cleaned"
else
  pass "artifact staging files are cleaned"
fi

assert_jq '.duration_precision == "milliseconds" and (.finished_at_epoch_ms >= .started_at_epoch_ms)' "$repo/reviews/artifact-write.d/execution.json" "execution timing declares millisecond precision"

if [[ -x "$script_dir/validate_skill.sh" ]]; then
  pass "self-contained skill validator exists and is executable"
  "$script_dir/validate_skill.sh" >/dev/null 2>&1
  rc=$?
  assert_eq 0 "$rc" "skill metadata validates without installing maintenance dependencies"
else
  fail "self-contained skill validator exists and is executable"
fi

if [[ "$failures" -ne 0 ]]; then
  printf '%s test(s) failed.\n' "$failures" >&2
  exit 1
fi

printf 'All ask-claude review runner tests passed.\n'
