#!/usr/bin/env bash
# test_run_review.sh - failure-path matrix for run_review.sh using a fake kimi.
# Covers: normal completion, non-zero exit, timeout, external signal, empty
# output, secret quarantine, prompt-only fallback, artifact-write failure,
# working-tree mutation attribution, and descendant residue.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runner="$script_dir/run_review.sh"
skill_dir="$(cd "$script_dir/.." && pwd)"

work="$(mktemp -d -t kimi-runner-test.XXXXXX)"
bin="$work/bin"
shim="$work/shim"
repo="$work/repo"
mkdir -p "$bin" "$shim" "$repo"

failures=0

cleanup_work() {
  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup_work EXIT

# ---------- fake kimi ----------

cat >"$bin/kimi" <<'FAKE_KIMI'
#!/usr/bin/env bash
mode="${FAKE_KIMI_MODE:-ok}"
for arg in "$@"; do
  case "$arg" in
    provider)
      printf '%s\n' '{"models":{"kimi-code/kimi-for-coding":{"capabilities":["image_in","video_in"],"provider":"managed:kimi-code"},"kimi-code/k3":{"capabilities":["image_in","video_in"],"provider":"managed:kimi-code"}}}'
      exit 0
      ;;
    --version|-V)
      printf '0.26.0-fake\n'
      exit 0
      ;;
  esac
done
case "$mode" in
  ok|mutate|mutate-tracked|residue|secret)
    if [[ "$mode" == "mutate" && -n "${FAKE_KIMI_MUTATE_PATH:-}" ]]; then
      printf 'concurrent edit\n' >"$FAKE_KIMI_MUTATE_PATH"
    fi
    if [[ "$mode" == "mutate-tracked" && -n "${FAKE_KIMI_MUTATE_PATH:-}" ]]; then
      printf 'concurrent tracked edit\n' >>"$FAKE_KIMI_MUTATE_PATH"
    fi
    if [[ "$mode" == "residue" ]]; then
      sleep 30 &
      [[ -n "${FAKE_STATE_DIR:-}" ]] && printf '%s\n' "$!" >"$FAKE_STATE_DIR/child.pid"
      sleep 1   # keep the child observable to the 0.2s tree sampler before exiting
    fi
    if [[ "$mode" == "secret" ]]; then
      printf '%s\n' '{"role":"assistant","content":"Found key AKIAIOSFODNN7EXAMPLE in config. 1. Verdict: NEEDS_ATTENTION"}'
      printf '%s\n' '{"role":"assistant","content":"Also sk-abcdefghij1234567890ab looks real. Still NEEDS_ATTENTION."}'
    else
      printf '%s\n' '{"role":"assistant","tool_calls":[{"type":"function","id":"t1","function":{"name":"Bash","arguments":"{\"command\":\"git diff\"}"}}]}'
      printf '%s\n' '{"role":"tool","tool_call_id":"t1","content":"diff --git a/f.txt b/f.txt"}'
      printf '%s\n' '{"role":"assistant","content":"1. Verdict: PASS\n\nNo findings."}'
    fi
    printf '%s\n' '{"role":"meta","type":"session.resume_hint","session_id":"session_fake","content":"resume hint"}'
    exit 0
    ;;
  boundary)
    # historical review filenames whose identifiers contain "sk-" mid-word:
    # must NOT trigger the sk-token rule after the left-boundary fix
    printf '%s\n' '{"role":"assistant","content":"Checked task-abc1234567890abcdef12345 and ask-def4567890abcdef1234567 plus task-8.6-membership-pagination-review-failures-20260726.md. 1. Verdict: PASS"}'
    printf '%s\n' '{"role":"meta","type":"session.resume_hint","session_id":"session_fake","content":"resume hint"}'
    exit 0
    ;;
  verdict-header)
    # markdown-header verdict form ("## 1. Verdict\n\n**PASS**") must also be
    # extracted, not only the inline "Verdict: PASS" form
    printf '%s\n' '{"role":"assistant","content":"## 1. Verdict\n\n**PASS**\n\nNo findings worth reporting."}'
    printf '%s\n' '{"role":"meta","type":"session.resume_hint","session_id":"session_fake","content":"resume hint"}'
    exit 0
    ;;
  verdict-json)
    # valid fenced JSON verdict contract supersedes the text heuristic
    printf '%s\n' '{"role":"assistant","content":"1. Verdict: PASS\n\nNo findings.\n\n```json\n{\"verdict\":\"PASS\",\"findings\":[],\"caveats\":\"none\"}\n```"}'
    printf '%s\n' '{"role":"meta","type":"session.resume_hint","session_id":"session_fake","content":"resume hint"}'
    exit 0
    ;;
  verdict-json-parenthetical)
    # The human verdict may contain a parenthetical explanation, while the
    # machine contract is pretty-printed and must be authoritative.
    printf '%s\n' '{"role":"assistant","content":"## 1. Verdict\n\nPASS (with one P3 hardening note).\n\n```json\n{\n  \"verdict\": \"PASS\",\n  \"findings\": [{\"severity\": \"P3\", \"summary\": \"minor hardening\"}],\n  \"caveats\": \"none\"\n}\n```"}'
    printf '%s\n' '{"role":"meta","type":"session.resume_hint","session_id":"session_fake","content":"resume hint"}'
    exit 0
    ;;
  verdict-json-invalid)
    # a shape-invalid JSON block (severity P9) is ignored; the text verdict stands
    printf '%s\n' '{"role":"assistant","content":"1. Verdict: NEEDS_ATTENTION\n\n```json\n{\"verdict\":\"PASS\",\"findings\":[{\"severity\":\"P9\",\"summary\":\"bad\"}]}\n```"}'
    printf '%s\n' '{"role":"meta","type":"session.resume_hint","session_id":"session_fake","content":"resume hint"}'
    exit 0
    ;;
  denial-relative)
    # a Bash denial with a relative target (no absolute path for rule b);
    # the line-anchored shell error shape via a Bash call is provenance
    printf '%s\n' '{"role":"assistant","tool_calls":[{"type":"function","id":"t9","function":{"name":"Bash","arguments":"{\"command\":\"cd /private && cat var/folders/x\"}"}}]}'
    printf '%s\n' '{"role":"tool","tool_call_id":"t9","content":"cat: var/folders/x: Operation not permitted"}'
    printf '%s\n' '{"role":"assistant","content":"1. Verdict: PASS"}'
    printf '%s\n' '{"role":"meta","type":"session.resume_hint","session_id":"session_fake","content":"resume hint"}'
    exit 0
    ;;
  read-oob)    allowed_out="$(cat "${FAKE_REPO:-.}/f.txt" 2>&1)"
    denied_out="$(cat "${FAKE_REPO:-.}/other.txt" 2>&1)"
    printf '%s\n' '{"role":"assistant","tool_calls":[{"type":"function","id":"t1","function":{"name":"Read","arguments":"{\"path\":\"f.txt\"}"}},{"type":"function","id":"t2","function":{"name":"Read","arguments":"{\"path\":\"other.txt\"}"}}]}'
    printf '%s\n' "{\"role\":\"tool\",\"tool_call_id\":\"t1\",\"content\":\"$allowed_out\"}"
    printf '%s\n' "{\"role\":\"tool\",\"tool_call_id\":\"t2\",\"content\":\"$denied_out\"}"
    printf '%s\n' '{"role":"assistant","content":"1. Verdict: NEEDS_ATTENTION"}'
    printf '%s\n' '{"role":"meta","type":"session.resume_hint","session_id":"session_fake","content":"resume hint"}'
    exit 0
    ;;
  git-bypass)
    # attempts to read an unchanged tracked file through the object database;
    # with the .git boundary closed this must be denied by the sandbox
    bypass_out="$(git -C "${FAKE_REPO:-.}" show HEAD:other.txt 2>&1 | head -1)"
    printf '%s\n' '{"role":"assistant","tool_calls":[{"type":"function","id":"t9","function":{"name":"Bash","arguments":"{\"command\":\"git show HEAD:other.txt\"}"}}]}'
    printf '%s\n' "{\"role\":\"tool\",\"tool_call_id\":\"t9\",\"content\":\"$bypass_out\"}"
    printf '%s\n' '{"role":"assistant","content":"1. Verdict: PASS"}'
    printf '%s\n' '{"role":"meta","type":"session.resume_hint","session_id":"session_fake","content":"resume hint"}'
    exit 0
    ;;
  read-outside)
    # attempts to read a probe OUTSIDE the repository and outside every allow
    # rule; deny-by-default must block it and the denial must be counted
    outside_out="$(cat "${FAKE_OUTSIDE_PROBE:-/nonexistent-probe}" 2>&1)"
    printf '%s\n' '{"role":"assistant","tool_calls":[{"type":"function","id":"t3","function":{"name":"Read","arguments":"{\"path\":\"outside-probe\"}"}}]}'
    printf '%s\n' "{\"role\":\"tool\",\"tool_call_id\":\"t3\",\"content\":\"$outside_out\"}"
    printf '%s\n' '{"role":"assistant","content":"1. Verdict: NEEDS_ATTENTION"}'
    printf '%s\n' '{"role":"meta","type":"session.resume_hint","session_id":"session_fake","content":"resume hint"}'
    exit 0
    ;;
  read-fixture)
    # echoes a changed file holding synthetic credentials into the stream;
    # without --projection this must quarantine the raw output
    fixture_out="$(cat "${FAKE_REPO:-.}/fixture.txt" 2>&1)"
    printf '%s\n' '{"role":"assistant","tool_calls":[{"type":"function","id":"t4","function":{"name":"Read","arguments":"{\"path\":\"fixture.txt\"}"}}]}'
    printf '%s\n' "{\"role\":\"tool\",\"tool_call_id\":\"t4\",\"content\":\"$fixture_out\"}"
    printf '%s\n' '{"role":"assistant","content":"1. Verdict: NEEDS_ATTENTION"}'
    printf '%s\n' '{"role":"meta","type":"session.resume_hint","session_id":"session_fake","content":"resume hint"}'
    exit 0
    ;;
  read-projection)
    # reads only the sanitized projection (the strict cwd is the projection
    # directory): files/fixture.txt and diff.patch
    proj_out="$(cat files/fixture.txt 2>&1)"
    snap_out="$(head -c 120 diff.patch 2>&1)"
    printf '%s\n' '{"role":"assistant","tool_calls":[{"type":"function","id":"t5","function":{"name":"Read","arguments":"{\"path\":\"files/fixture.txt\"}"}}]}'
    printf '%s\n' "{\"role\":\"tool\",\"tool_call_id\":\"t5\",\"content\":\"$proj_out\"}"
    printf '%s\n' "{\"role\":\"tool\",\"tool_call_id\":\"t6\",\"content\":\"$snap_out\"}"
    printf '%s\n' '{"role":"assistant","content":"1. Verdict: PASS"}'
    printf '%s\n' '{"role":"meta","type":"session.resume_hint","session_id":"session_fake","content":"resume hint"}'
    exit 0
    ;;
  projection-raw-read)
    # Projection must count an attempted read of the original diff snapshot.
    raw_snapshot="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'kimi-review-diff.*' -print -quit 2>/dev/null)"
    raw_outcome="$(cat "$raw_snapshot" 2>&1)"
    printf '%s\n' "$(jq -cn --arg path "$raw_snapshot" '{role:"assistant",tool_calls:[{type:"function",id:"t7",function:{name:"Bash",arguments:(\"{\\\"command\\\":\\\"cat \" + $path + \"\\\"}\")}}]}')"
    printf '%s\n' "$(jq -cn --arg content "$raw_outcome" '{role:"tool",tool_call_id:"t7",content:$content}')"
    printf '%s\n' '{"role":"assistant","content":"1. Verdict: PASS"}'
    printf '%s\n' '{"role":"meta","type":"session.resume_hint","session_id":"session_fake","content":"resume hint"}'
    exit 0
    ;;
  read-changed)
    # Reads the repository-relative changed-file copy from strict cwd.
    changed_out="$(cat f.txt 2>&1)"
    printf '%s\n' '{"role":"assistant","tool_calls":[{"type":"function","id":"t8","function":{"name":"Read","arguments":"{\"path\":\"f.txt\"}"}}]}'
    printf '%s\n' "$(jq -cn --arg content "$changed_out" '{role:"tool",tool_call_id:"t8",content:$content}')"
    printf '%s\n' '{"role":"assistant","content":"1. Verdict: PASS"}'
    printf '%s\n' '{"role":"meta","type":"session.resume_hint","session_id":"session_fake","content":"resume hint"}'
    exit 0
    ;;
  phrase-fixture)
    # echoes allowed in-scope content that merely QUOTES the denial phrases;
    # the provenance classifier must not count these as scope violations
    phrase_out="$(cat "${FAKE_REPO:-.}/phrases.txt" 2>&1)"
    printf '{"role":"assistant","tool_calls":[{"type":"function","id":"t7","function":{"name":"Read","arguments":"{\"path\":\"%s\"}"}}]}\n' "${FAKE_REPO:-.}/phrases.txt"
    printf '%s\n' "{\"role\":\"tool\",\"tool_call_id\":\"t7\",\"content\":\"$phrase_out\"}"
    printf '%s\n' '{"role":"assistant","content":"1. Verdict: PASS"}'
    printf '%s\n' '{"role":"meta","type":"session.resume_hint","session_id":"session_fake","content":"resume hint"}'
    exit 0
    ;;
  read-media)
    # simulates ReadMediaFile on an explicitly authorized media path
    media_out="$(cat "${FAKE_MEDIA_PATH:-/nonexistent-media}" 2>&1)"
    printf '%s\n' '{"role":"assistant","tool_calls":[{"type":"function","id":"t8","function":{"name":"ReadMediaFile","arguments":"{\"path\":\"media\"}"}}]}'
    printf '%s\n' "{\"role\":\"tool\",\"tool_call_id\":\"t8\",\"content\":\"$media_out\"}"
    printf '%s\n' '{"role":"assistant","content":"1. Verdict: PASS"}'
    printf '%s\n' '{"role":"meta","type":"session.resume_hint","session_id":"session_fake","content":"resume hint"}'
    exit 0
    ;;
  nonzero)
    printf '%s\n' '{"role":"assistant","content":"provider exploded mid-review"}'
    printf 'error: provider.api_error: 403 You have reached your usage limit for this billing cycle\n' >&2
    exit 7
    ;;
  sleep)
    sleep "${FAKE_KIMI_SLEEP:-60}"
    exit 0
    ;;
  self-kill)
    kill -KILL "$$"
    ;;
  empty)
    exit 0
    ;;
  *)
    printf 'unknown FAKE_KIMI_MODE: %s\n' "$mode" >&2
    exit 99
    ;;
esac
FAKE_KIMI
chmod +x "$bin/kimi"

cat >"$shim/uname" <<'FAKE_UNAME'
#!/usr/bin/env bash
printf 'Linux\n'
FAKE_UNAME
chmod +x "$shim/uname"

# ---------- temp git repo ----------

git -C "$repo" init -q
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
printf 'line1 CHANGED-CONTENT-777\n' >"$repo/f.txt"
printf 'OOB-SECRET-DATA\n' >"$repo/other.txt"
printf 'notes v1\n' >"$repo/phrases.txt"
git -C "$repo" add f.txt other.txt phrases.txt
git -C "$repo" commit -qm init
printf 'line2\n' >>"$repo/f.txt"   # non-empty git diff for the default scope
cat >>"$repo/phrases.txt" <<'PHRASES'
Runbook excerpt: when the sandbox denies a read you see cat: file.txt: Operation not permitted
and git prints fatal: not a git repository when the directory is invisible.
PHRASES

# ---------- helpers ----------

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

assert_contains() {
  local name="$1" file="$2" text="$3"
  if grep -qF -- "$text" "$file"; then pass "$name"; else
    fail "$name (missing: $text)"
  fi
}

assert_not_contains() {
  local name="$1" file="$2" text="$3"
  if grep -qF -- "$text" "$file"; then
    fail "$name (unexpected: $text)"
  else
    pass "$name"
  fi
}

assert_jq() {
  local name="$1" file="$2" expr="$3"
  if jq -e "$expr" "$file" >/dev/null 2>&1; then pass "$name"; else
    fail "$name (jq: $expr)"
  fi
}

# run_case <name> <mode> <extra-env...> -- <runner args...>
run_case() {
  local name="$1" mode="$2"
  shift 2
  local extra_env=()
  while [[ "$1" != "--" ]]; do extra_env+=("$1"); shift; done
  shift
  local out="$work/$name.runner.log"
  set +e
  (cd "$repo" && env PATH="$bin:$PATH" KIMI_REVIEW_SKILL_DIR="$skill_dir" FAKE_KIMI_MODE="$mode" ${extra_env[@]+"${extra_env[@]}"} "$runner" "$@") >"$out" 2>&1
  echo $?
  set -e
}

artifact_for() {
  { ls "$repo/artifacts"/kimi-"$1"-*.md 2>/dev/null || true; } | head -1
}

set -e

# ---------- case: normal completion ----------

rc="$(run_case ok ok -- --slug ok --artifact-dir "$repo/artifacts")"
art="$(artifact_for ok)"
[[ "$rc" == "0" ]] && pass "ok: runner exit 0" || fail "ok: runner exit $rc"
[[ -n "$art" ]] || fail "ok: artifact missing"
if [[ -n "$art" ]]; then
  assert_contains "ok: status completed" "$art" "- Status: COMPLETED"
  assert_contains "ok: exit code" "$art" "- Exit code: \`0\`"
  assert_contains "ok: timed out false" "$art" "- Timed out: \`false\`"
  assert_contains "ok: verdict" "$art" "- Verdict (heuristic): \`PASS\`"
  assert_contains "ok: tool summary" "$art" "- Tool-use summary: Bash x1"
  assert_contains "ok: provider identity" "$art" "- Provider identity (catalog): \`managed:kimi-code\`"
  assert_contains "ok: kimi session" "$art" "- Kimi session: \`session_fake\`"
  assert_contains "ok: mutation unchanged" "$art" "working tree unchanged during Kimi review (HEAD "
  assert_contains "ok: process release" "$art" "all descendants observed in sampled tree evidence exited"
  assert_contains "ok: temp release" "$art" "- Temporary release: all review temporary files removed"
  assert_contains "ok: raw stream-json" "$art" "## Raw Kimi stdout (stream-json)"
  assert_contains "ok: snapshot sha" "$art" "- Snapshot SHA-256: \`"
  assert_contains "ok: sandbox isolation" "$art" "macOS sandbox: repository, git, and skill writes denied"
  assert_contains "ok: runtime evidence class" "$art" "NOT stage-gate evidence"
  if [[ -f "${art%.md}.d/execution.json" ]]; then
    pass "ok: execution.json sidecar exists"
    assert_jq "ok: sidecar status" "${art%.md}.d/execution.json" '.status == "COMPLETED"'
    assert_jq "ok: sidecar terminal_reason" "${art%.md}.d/execution.json" '.terminal_reason == "completed"'
    assert_jq "ok: sidecar gate eligible" "${art%.md}.d/execution.json" '.gate_eligible == true'
    assert_jq "ok: sidecar scope open" "${art%.md}.d/execution.json" '.scope_mode == "open"'
    assert_jq "ok: sidecar no secret" "${art%.md}.d/execution.json" '.secret_scan.detected == false and .secret_scan.scan_failed == false'
    assert_jq "ok: sidecar no mutation" "${art%.md}.d/execution.json" '.mutation.detected == false'
    assert_jq "ok: sidecar snapshot sha" "${art%.md}.d/execution.json" '.snapshot_sha256 | length == 64'
    assert_jq "ok: duration_ms numeric" "${art%.md}.d/execution.json" '.duration_ms > 0 and .duration_precision == "milliseconds"'
    assert_jq "ok: epoch fields" "${art%.md}.d/execution.json" '(.started_at_epoch_ms | type) == "number" and (.finished_at_epoch_ms >= .started_at_epoch_ms)'
    assert_jq "ok: timed_out bool" "${art%.md}.d/execution.json" '.timed_out == false'
    assert_jq "ok: failure_reason null" "${art%.md}.d/execution.json" '.failure_reason == null'
    assert_jq "ok: resources sampled" "${art%.md}.d/execution.json" '(.resources.sampled_pids | length) >= 1 and .resources.remaining_pids == []'
    for sidecar_file in prompt.txt stdout.jsonl stderr.log command.txt process-tree.log sandbox.sb git-before.json git-after.json git-before.status git-after.status; do
      [[ -f "${art%.md}.d/$sidecar_file" ]] && pass "ok: sidecar file $sidecar_file" || fail "ok: sidecar file $sidecar_file missing"
    done
    assert_jq "ok: git-before head" "${art%.md}.d/git-before.json" '.head | length == 40'
  else
    fail "ok: execution.json sidecar missing"
  fi
fi

# ---------- case: require-verdict passes on eligible review ----------

rc="$(run_case ok-req ok -- --slug ok-req --artifact-dir "$repo/artifacts" --require-verdict)"
[[ "$rc" == "0" ]] && pass "require-verdict: eligible review exits 0" || fail "require-verdict: eligible review exit $rc"

# ---------- case: durable copy ----------

rc="$(run_case durable ok -- --slug durable --artifact-dir "$repo/artifacts" --durable-dir "$repo/gate")"
art="$(artifact_for durable)"
[[ "$rc" == "0" ]] && pass "durable: runner exit 0" || fail "durable: runner exit $rc"
gate_art="$( { ls "$repo/gate"/kimi-durable-*.md 2>/dev/null || true; } | head -1)"
[[ -n "$gate_art" ]] && pass "durable: gate markdown exists" || fail "durable: gate markdown missing"
[[ -n "$art" ]] && assert_contains "durable: evidence class" "$art" "durable gate evidence (repo-governed path: $repo/gate)"
if [[ -n "$gate_art" ]]; then
  [[ -f "${gate_art%.md}.d/execution.json" ]] && pass "durable: gate sidecar exists" || fail "durable: gate sidecar missing"
  [[ -f "${gate_art%.md}.d/execution.json" ]] && assert_jq "durable: gate record eligible" "${gate_art%.md}.d/execution.json" '.gate_eligible == true and .status == "COMPLETED"'
  assert_contains "durable: markdown self-contained" "$gate_art" "## Resource Cleanup"
  assert_contains "durable: relative record link" "$gate_art" '- Execution record (JSON): `./'
  for sidecar_file in prompt.txt command.txt sandbox.sb stdout.jsonl stderr.log process-tree.log git-before.json git-after.json; do
    [[ -f "${gate_art%.md}.d/$sidecar_file" ]] && pass "durable: gate sidecar file $sidecar_file" || fail "durable: gate sidecar file $sidecar_file missing"
  done
fi

# ---------- case: durable copy failure is gate-fatal ----------

mkdir -p "$work/gate-locked"
chmod 555 "$work/gate-locked"
rc="$(run_case gatefail ok -- --slug gatefail --artifact-dir "$repo/artifacts" --durable-dir "$work/gate-locked/sub" --require-verdict)"
chmod 755 "$work/gate-locked"
art="$(artifact_for gatefail)"
[[ "$rc" == "4" ]] && pass "gatefail: require-verdict exit 4" || fail "gatefail: exit $rc (want 4)"
if [[ -n "$art" ]]; then
  assert_contains "gatefail: evidence marked failed" "$art" "durable gate evidence copy FAILED"
  assert_contains "gatefail: reason listed" "$art" "durable-copy-failure"
  assert_jq "gatefail: sidecar not eligible" "${art%.md}.d/execution.json" '.gate_eligible == false and .failure_reason == "durable-copy-failure"'
else
  fail "gatefail: artifact missing"
fi

# ---------- case: non-zero review exit (provider failure classification) ----------

rc="$(run_case nonzero nonzero -- --slug nonzero --artifact-dir "$repo/artifacts")"
art="$(artifact_for nonzero)"
[[ "$rc" == "0" ]] && pass "nonzero: runner exit 0" || fail "nonzero: runner exit $rc"
if [[ -n "$art" ]]; then
  assert_contains "nonzero: exit code 7" "$art" "- Exit code: \`7\`"
  assert_contains "nonzero: status FAILED" "$art" "- Status: FAILED"
  assert_not_contains "nonzero: not COMPLETED" "$art" "- Status: COMPLETED"
  assert_jq "nonzero: sidecar failed" "${art%.md}.d/execution.json" '.status == "FAILED" and .terminal_reason == "failed"'
  assert_jq "nonzero: provider reason" "${art%.md}.d/execution.json" '.failure_reason == "provider-api-error" and (.gate_ineligible_reasons | index("provider-api-error") != null) and (.gate_ineligible_reasons | index("nonzero-review-exit") != null)'
else
  fail "nonzero: artifact missing"
fi

# ---------- case: outer timeout ----------

rc="$(run_case timeout sleep FAKE_KIMI_SLEEP=60 KIMI_REVIEW_TIMEOUT_SECONDS=2 -- --slug timeout --artifact-dir "$repo/artifacts")"
art="$(artifact_for timeout)"
[[ "$rc" == "0" ]] && pass "timeout: runner exit 0" || fail "timeout: runner exit $rc"
if [[ -n "$art" ]]; then
  assert_contains "timeout: status" "$art" "- Status: TIMED_OUT"
  assert_contains "timeout: timed_out flag" "$art" "- Timed out: \`true"
  assert_contains "timeout: incomplete note" "$art" "is incomplete"
fi

# ---------- case: external SIGTERM ----------

set +e
(cd "$repo" && exec env PATH="$bin:$PATH" KIMI_REVIEW_SKILL_DIR="$skill_dir" FAKE_KIMI_MODE=sleep FAKE_KIMI_SLEEP=60 "$runner" --slug interrupt --artifact-dir "$repo/artifacts") >"$work/interrupt.runner.log" 2>&1 &
runner_pid=$!
set -e
sleep 3
kill -TERM "$runner_pid"
rc=0
wait "$runner_pid" || rc=$?
art="$(artifact_for interrupt)"
[[ "$rc" == "143" ]] && pass "interrupt: runner exit 143" || fail "interrupt: runner exit $rc (want 143)"
if [[ -n "$art" ]]; then
  assert_contains "interrupt: status" "$art" "- Status: INTERRUPTED (SIGTERM)"
  assert_contains "interrupt: external signal" "$art" "- Termination signal: \`SIGTERM (external)\`"
  assert_contains "interrupt: incomplete note" "$art" "the review is incomplete"
  assert_contains "interrupt: evidence finalized" "$art" "## Resource Cleanup"
  assert_contains "interrupt: anti-short-SLA note" "$art" "do not terminate review runs before the"
else
  fail "interrupt: artifact missing"
fi

# ---------- case: empty output ----------

rc="$(run_case empty empty -- --slug empty --artifact-dir "$repo/artifacts")"
art="$(artifact_for empty)"
[[ "$rc" == "0" ]] && pass "empty: runner exit 0" || fail "empty: runner exit $rc"
[[ -n "$art" ]] && assert_contains "empty: warning" "$art" "Kimi stdout was empty"

# ---------- case: secret quarantine ----------

rc="$(run_case secret secret -- --slug secret --artifact-dir "$repo/artifacts")"
art="$(artifact_for secret)"
[[ "$rc" == "0" ]] && pass "secret: runner exit 0" || fail "secret: runner exit $rc"
if [[ -n "$art" ]]; then
  assert_contains "secret: quarantine notice" "$art" "was quarantined"
  assert_contains "secret: pattern name" "$art" "aws-access-key"
  assert_contains "secret: sk-token still caught" "$art" "sk-token"
  assert_not_contains "secret: key not published" "$art" "AKIAIOSFODNN7EXAMPLE"
  assert_not_contains "secret: sk value not published" "$art" "sk-abcdefghij1234567890ab"
  assert_jq "secret: sidecar not gate eligible" "${art%.md}.d/execution.json" '.gate_eligible == false and (.gate_ineligible_reasons | index("secret-quarantine") != null)'
  assert_contains "secret: retained evidence" "$art" "Quarantined (retained) raw files:"
  retained="${art%.md}.d/stdout.quarantined.jsonl"
  if [[ -f "$retained" ]]; then
    pass "secret: raw file retained in sidecar"
    grep -q "AKIAIOSFODNN7EXAMPLE" "$retained" && pass "secret: retained raw contains the evidence" || fail "secret: retained raw lost the evidence"
    perms="$(stat -f '%Lp' "$retained")"
    [[ "$perms" == "600" ]] && pass "secret: retained raw chmod 600" || fail "secret: retained raw perms $perms"
  else
    fail "secret: retained raw file missing in sidecar"
  fi
else
  fail "secret: artifact missing"
fi

# ---------- case: prompt-only fallback (no sandbox platform) ----------

out="$work/promptonly.runner.log"
set +e
(cd "$repo" && env PATH="$shim:$bin:$PATH" KIMI_REVIEW_SKILL_DIR="$skill_dir" FAKE_KIMI_MODE=ok "$runner" --slug promptonly --artifact-dir "$repo/artifacts") >"$out" 2>&1
rc=$?
set -e
art="$(artifact_for promptonly)"
[[ "$rc" == "0" ]] && pass "prompt-only: runner exit 0" || fail "prompt-only: runner exit $rc"
[[ -n "$art" ]] && assert_contains "prompt-only: isolation" "$art" "- Isolation: prompt-only"

# ---------- case: mutation attribution ----------

out="$work/mutate.runner.log"
set +e
(cd "$repo" && env PATH="$shim:$bin:$PATH" KIMI_REVIEW_SKILL_DIR="$skill_dir" FAKE_KIMI_MODE=mutate FAKE_KIMI_MUTATE_PATH="$repo/mutated.txt" "$runner" --slug mutate --artifact-dir "$repo/artifacts") >"$out" 2>&1
rc=$?
set -e
art="$(artifact_for mutate)"
[[ "$rc" == "0" ]] && pass "mutate: runner exit 0" || fail "mutate: runner exit $rc"
if [[ -n "$art" ]]; then
  assert_contains "mutate: warning" "$art" "The working tree changed during the Kimi process"
  assert_contains "mutate: changed file listed" "$art" "mutated.txt"
  assert_contains "mutate: changed fields named" "$art" "changed: status"
  assert_jq "mutate: sidecar detected" "${art%.md}.d/execution.json" '.mutation.detected == true and (.mutation.changed | index("status") != null)'
fi
rm -f "$repo/mutated.txt"

# ---------- case: tracked-file mutation fingerprints ----------

out="$work/mutate-tracked.runner.log"
set +e
(cd "$repo" && env PATH="$shim:$bin:$PATH" KIMI_REVIEW_SKILL_DIR="$skill_dir" FAKE_KIMI_MODE=mutate-tracked FAKE_KIMI_MUTATE_PATH="$repo/f.txt" "$runner" --slug mutate-tracked --artifact-dir "$repo/artifacts") >"$out" 2>&1
rc=$?
set -e
art="$(artifact_for mutate-tracked)"
[[ "$rc" == "0" ]] && pass "mutate-tracked: runner exit 0" || fail "mutate-tracked: runner exit $rc"
if [[ -n "$art" ]]; then
  assert_contains "mutate-tracked: warning" "$art" "The working tree changed during the Kimi process"
  assert_jq "mutate-tracked: worktree-diff changed" "${art%.md}.d/execution.json" '.mutation.changed | index("worktree-diff") != null'
  assert_jq "mutate-tracked: index/head unchanged" "${art%.md}.d/execution.json" '(.mutation.changed | index("index") == null) and (.mutation.changed | index("head") == null)'
  assert_jq "mutate-tracked: git state sidecars" "${art%.md}.d/git-after.json" '.worktree_fingerprint | length == 64'
fi
git -C "$repo" checkout -q -- f.txt
printf 'line2\n' >>"$repo/f.txt"   # restore the shared uncommitted change other cases rely on

# ---------- case: descendant residue ----------

rc="$(run_case residue residue FAKE_STATE_DIR="$work" -- --slug residue --artifact-dir "$repo/artifacts")"
art="$(artifact_for residue)"
[[ "$rc" == "0" ]] && pass "residue: runner exit 0" || fail "residue: runner exit $rc"
if [[ -n "$art" ]]; then
  assert_contains "residue: warning" "$art" "remain after completion"
  assert_jq "residue: remaining recorded" "${art%.md}.d/execution.json" '(.resources.remaining_pids | length) >= 1'
  if [[ -f "$work/child.pid" ]]; then
    child_pid="$(cat "$work/child.pid")"
    if kill -0 "$child_pid" 2>/dev/null; then
      kill "$child_pid" 2>/dev/null && pass "residue: exact child PID cleaned by test"
    else
      fail "residue: recorded child PID $child_pid not alive for cleanup check"
    fi
  else
    fail "residue: child.pid not recorded"
  fi
else
  fail "residue: artifact missing"
fi

# ---------- case: artifact dir unwritable ----------

mkdir -p "$work/locked"
chmod 555 "$work/locked"
out="$work/locked.runner.log"
set +e
(cd "$repo" && env PATH="$bin:$PATH" KIMI_REVIEW_SKILL_DIR="$skill_dir" FAKE_KIMI_MODE=ok "$runner" --slug locked --artifact-dir "$work/locked/sub") >"$out" 2>&1
rc=$?
set -e
chmod 755 "$work/locked"
[[ "$rc" == "3" ]] && pass "locked: runner exit 3" || fail "locked: runner exit $rc (want 3)"
grep -q "Unable to create the review artifact directory" "$out" && pass "locked: error message" || fail "locked: missing error message"
ls "$work/locked/sub" >/dev/null 2>&1 && fail "locked: artifact should not exist" || pass "locked: no artifact written"

# ---------- case: unborn HEAD (no commits) ----------

repo2="$work/repo2"
mkdir -p "$repo2"
git -C "$repo2" init -q
out="$work/unborn.runner.log"
set +e
(cd "$repo2" && env PATH="$bin:$PATH" KIMI_REVIEW_SKILL_DIR="$skill_dir" FAKE_KIMI_MODE=ok "$runner" --slug unborn --artifact-dir "$repo2/artifacts") >"$out" 2>&1
rc=$?
set -e
art="$( { ls "$repo2/artifacts"/kimi-unborn-*.md 2>/dev/null || true; } | head -1)"
[[ "$rc" == "0" ]] && pass "unborn: runner exit 0" || fail "unborn: runner exit $rc"
if [[ -n "$art" ]]; then
  assert_contains "unborn: status completed" "$art" "- Status: COMPLETED"
  assert_contains "unborn: head note" "$art" "unborn (no commits)"
  assert_contains "unborn: no false mutation" "$art" "working tree unchanged during Kimi review (HEAD unborn (no commits);"
else
  fail "unborn: artifact missing"
fi

# ---------- case: sk-token boundary (no false positive on identifiers) ----------

rc="$(run_case boundary boundary -- --slug boundary --artifact-dir "$repo/artifacts")"
art="$(artifact_for boundary)"
[[ "$rc" == "0" ]] && pass "boundary: runner exit 0" || fail "boundary: runner exit $rc"
if [[ -n "$art" ]]; then
  assert_not_contains "boundary: no quarantine" "$art" "was quarantined"
  assert_contains "boundary: verdict extracted" "$art" "- Verdict (heuristic): \`PASS\`"
  assert_jq "boundary: sidecar eligible" "${art%.md}.d/execution.json" '.gate_eligible == true and .secret_scan.detected == false'
else
  fail "boundary: artifact missing"
fi

# ---------- case: markdown-header verdict extraction ----------

rc="$(run_case verdict-header verdict-header -- --slug verdict-header --artifact-dir "$repo/artifacts" --require-verdict)"
art="$(artifact_for verdict-header)"
[[ "$rc" == "0" ]] && pass "verdict-header: runner exit 0" || fail "verdict-header: runner exit $rc"
if [[ -n "$art" ]]; then
  assert_contains "verdict-header: verdict extracted" "$art" "- Verdict (heuristic): \`PASS\`"
  assert_jq "verdict-header: sidecar eligible" "${art%.md}.d/execution.json" '.gate_eligible == true'
  assert_jq "verdict-header: contract text" "${art%.md}.d/execution.json" '.verdict == "PASS" and .verdict_contract == "text-heuristic"'
else
  fail "verdict-header: artifact missing"
fi

# ---------- case: fenced JSON verdict contract ----------

rc="$(run_case verdict-json verdict-json -- --slug verdict-json --artifact-dir "$repo/artifacts" --require-verdict)"
art="$(artifact_for verdict-json)"
[[ "$rc" == "0" ]] && pass "verdict-json: runner exit 0" || fail "verdict-json: runner exit $rc"
if [[ -n "$art" ]]; then
  assert_contains "verdict-json: schema verdict" "$art" "- Verdict (schema): \`PASS\`"
  assert_jq "verdict-json: contract schema" "${art%.md}.d/execution.json" '.verdict == "PASS" and .verdict_contract == "json-schema" and .gate_eligible == true'
else
  fail "verdict-json: artifact missing"
fi

rc="$(run_case verdict-json-parenthetical verdict-json-parenthetical -- --slug verdict-json-parenthetical --artifact-dir "$repo/artifacts" --require-verdict)"
art="$(artifact_for verdict-json-parenthetical)"
[[ "$rc" == "0" ]] && pass "verdict-json-parenthetical: runner exit 0" || fail "verdict-json-parenthetical: runner exit $rc"
if [[ -n "$art" ]]; then
  assert_contains "verdict-json-parenthetical: schema verdict" "$art" "- Verdict (schema): \`PASS\`"
  assert_jq "verdict-json-parenthetical: contract schema" "${art%.md}.d/execution.json" '.verdict == "PASS" and .verdict_contract == "json-schema" and .gate_eligible == true'
else
  fail "verdict-json-parenthetical: artifact missing"
fi

rc="$(run_case verdict-json-inv verdict-json-invalid -- --slug verdict-json-inv --artifact-dir "$repo/artifacts" --require-verdict)"
art="$(artifact_for verdict-json-inv)"
[[ "$rc" == "0" ]] && pass "verdict-json-inv: runner exit 0" || fail "verdict-json-inv: runner exit $rc"
if [[ -n "$art" ]]; then
  assert_contains "verdict-json-inv: invalid block ignored" "$art" "- Verdict (heuristic): \`NEEDS_ATTENTION\`"
  assert_jq "verdict-json-inv: contract falls back" "${art%.md}.d/execution.json" '.verdict == "NEEDS_ATTENTION" and .verdict_contract == "text-heuristic"'
else
  fail "verdict-json-inv: artifact missing"
fi

# ---------- case: relative-target Bash denial is counted ----------

rc="$(run_case denial-rel denial-relative -- --slug denial-rel --artifact-dir "$repo/artifacts" --strict-scope)"
art="$(artifact_for denial-rel)"
[[ "$rc" == "0" ]] && pass "denial-rel: runner exit 0" || fail "denial-rel: runner exit $rc"
if [[ -n "$art" ]]; then
  assert_jq "denial-rel: violation counted" "${art%.md}.d/execution.json" '.scope_violation_attempts >= 1 and .scope_violation_events >= 1'
  assert_jq "denial-rel: not eligible" "${art%.md}.d/execution.json" '.gate_eligible == false and (.gate_ineligible_reasons | index("scope-violation-attempt") != null)'
else
  fail "denial-rel: artifact missing"
fi

# ---------- case: strict-scope sandbox enforcement ----------

rc="$(run_case strict read-oob FAKE_REPO="$repo" -- --slug strict --artifact-dir "$repo/artifacts" --strict-scope)"
art="$(artifact_for strict)"
[[ "$rc" == "0" ]] && pass "strict: runner exit 0" || fail "strict: runner exit $rc"
if [[ -n "$art" ]]; then
  assert_contains "strict: changed file readable" "$art" "CHANGED-CONTENT-777"
  assert_not_contains "strict: out-of-scope content withheld" "$art" "OOB-SECRET-DATA"
  assert_contains "strict: violation warning" "$art" "out-of-scope read attempt(s) were denied"
  assert_jq "strict: sidecar scope mode" "${art%.md}.d/execution.json" '.scope_mode == "strict"'
  assert_jq "strict: sidecar violations counted" "${art%.md}.d/execution.json" '.scope_violation_attempts >= 1 and .scope_violation_events >= 1 and (.scope_violation_log_hits | type) == "number"'
  assert_jq "strict: sidecar not eligible" "${art%.md}.d/execution.json" '.gate_eligible == false and (.gate_ineligible_reasons | index("scope-violation-attempt") != null)'
  assert_not_contains "strict: git objects closed" "${art%.md}.d/sandbox.sb" '(allow file-read* (subpath (param "GIT_DIR")))'
  assert_not_contains "strict: no git literal allow" "${art%.md}.d/sandbox.sb" '(allow file-read* (literal (param "GIT_DIR")))'
  assert_not_contains "strict: no workspace literal allow" "${art%.md}.d/sandbox.sb" '(allow file-read* (literal (param "WORKSPACE")))'
  assert_contains "strict: profile is deny-by-default" "${art%.md}.d/sandbox.sb" '(deny default)'
  assert_not_contains "strict: no global read allow" "${art%.md}.d/sandbox.sb" '(allow file-read*)'
else
  fail "strict: artifact missing"
fi

# ---------- case: git-object bypass is denied under strict scope ----------

rc="$(run_case gitbypass git-bypass FAKE_REPO="$repo" -- --slug gitbypass --artifact-dir "$repo/artifacts" --strict-scope)"
art="$(artifact_for gitbypass)"
[[ "$rc" == "0" ]] && pass "gitbypass: runner exit 0" || fail "gitbypass: runner exit $rc"
if [[ -n "$art" ]]; then
  assert_not_contains "gitbypass: object content withheld" "$art" "OOB-SECRET-DATA"
  assert_jq "gitbypass: events counted" "${art%.md}.d/execution.json" '.scope_violation_events >= 1'
  assert_jq "gitbypass: not eligible" "${art%.md}.d/execution.json" '.gate_eligible == false and (.gate_ineligible_reasons | index("scope-violation-attempt") != null)'
else
  fail "gitbypass: artifact missing"
fi

# ---------- case: strict pathspec must match the actual diff ----------

out="$work/strict-ps.runner.log"
set +e
(cd "$repo" && env PATH="$bin:$PATH" KIMI_REVIEW_SKILL_DIR="$skill_dir" FAKE_KIMI_MODE=ok "$runner" --slug strict-ps --artifact-dir "$repo/artifacts" --strict-scope -- other.txt) >"$out" 2>&1
rc=$?
set -e
[[ "$rc" == "2" ]] && pass "strict-ps: unchanged pathspec rejected" || fail "strict-ps: exit $rc (want 2)"
grep -q "has no changes in the selected diff" "$out" && pass "strict-ps: rejection message" || fail "strict-ps: rejection message missing"
[[ -z "$(artifact_for strict-ps)" ]] && pass "strict-ps: no artifact created" || fail "strict-ps: should not create an artifact"

rc="$(run_case strict-ps-ok ok -- --slug strict-ps-ok --artifact-dir "$repo/artifacts" --strict-scope -- f.txt)"
[[ "$rc" == "0" ]] && pass "strict-ps: changed pathspec accepted" || fail "strict-ps: changed pathspec exit $rc"

# ---------- case: require-verdict rejects ineligible reviews ----------

rc="$(run_case empty-req empty -- --slug empty-req --artifact-dir "$repo/artifacts" --require-verdict)"
[[ "$rc" == "4" ]] && pass "require-verdict: empty output exits 4" || fail "require-verdict: empty output exit $rc (want 4)"

rc="$(run_case strict-req read-oob FAKE_REPO="$repo" -- --slug strict-req --artifact-dir "$repo/artifacts" --strict-scope --require-verdict)"
[[ "$rc" == "4" ]] && pass "require-verdict: scope violation exits 4" || fail "require-verdict: scope violation exit $rc (want 4)"

# ---------- case: scope/diff-args binding ----------

out="$work/scope-mismatch.runner.log"
set +e
(cd "$repo" && env PATH="$bin:$PATH" KIMI_REVIEW_SKILL_DIR="$skill_dir" FAKE_KIMI_MODE=ok "$runner" --scope "git diff --cached" --slug scope-mismatch --artifact-dir "$repo/artifacts" -- main..HEAD) >"$out" 2>&1
rc=$?
set -e
[[ "$rc" == "2" ]] && pass "scope: mismatch rejected" || fail "scope: mismatch exit $rc (want 2)"
grep -q "Scope text does not match" "$out" && pass "scope: mismatch message" || fail "scope: mismatch message missing"
[[ -z "$(artifact_for scope-mismatch)" ]] && pass "scope: mismatch leaves no artifact" || fail "scope: mismatch should not create an artifact"

rc="$(run_case scope-canon ok -- --slug scope-canon --artifact-dir "$repo/artifacts" -- --cached)"
art="$(artifact_for scope-canon)"
[[ "$rc" == "0" ]] && pass "scope: derived scope accepted" || fail "scope: derived scope exit $rc"
if [[ -n "$art" ]]; then
  assert_contains "scope: derived scope text" "$art" 'Review scope: `git diff --cached`'
  assert_jq "scope: diff_args recorded" "${art%.md}.d/execution.json" '.diff_args == ["--cached"]'
else
  fail "scope: artifact missing"
fi

# ---------- case: strict scope with revision ranges ----------

repo3="$work/repo3"
mkdir -p "$repo3"
git -C "$repo3" init -q
git -C "$repo3" config user.email test@example.com
git -C "$repo3" config user.name test
printf 'v1\n' >"$repo3/f.txt"
printf 'untouched\n' >"$repo3/other.txt"
git -C "$repo3" add .
git -C "$repo3" commit -qm c1
printf 'v2\n' >>"$repo3/f.txt"
git -C "$repo3" commit -qam c2
printf 'v3\n' >>"$repo3/f.txt"
git -C "$repo3" commit -qam c3

run_repo3() {
  local name="$1"; shift
  local fake_mode=ok
  if [[ "${1:-}" == "--fake-mode" ]]; then
    fake_mode="$2"
    shift 2
  fi
  local out="$work/$name.runner.log"
  set +e
  (cd "$repo3" && env PATH="$bin:$PATH" KIMI_REVIEW_SKILL_DIR="$skill_dir" FAKE_KIMI_MODE="$fake_mode" "$runner" --slug "$name" --artifact-dir "$repo3/artifacts" --strict-scope "$@") >"$out" 2>&1
  echo $?
  set -e
}

rc="$(run_repo3 strict-range -- HEAD~1..HEAD)"
[[ "$rc" == "0" ]] && pass "strict-range: HEAD~1..HEAD accepted" || fail "strict-range: HEAD~1..HEAD exit $rc"
rc="$(run_repo3 strict-range3 -- HEAD~2...HEAD)"
[[ "$rc" == "0" ]] && pass "strict-range: three-dot range accepted" || fail "strict-range: three-dot range exit $rc"
rc="$(run_repo3 strict-range-path -- HEAD~1..HEAD -- f.txt)"
[[ "$rc" == "0" ]] && pass "strict-range: range + changed pathspec accepted" || fail "strict-range: range + changed pathspec exit $rc"
rc="$(run_repo3 strict-range-bad -- HEAD~1..HEAD -- other.txt)"
[[ "$rc" == "2" ]] && pass "strict-range: range + unchanged pathspec rejected" || fail "strict-range: range + unchanged pathspec exit $rc (want 2)"

# A dirty worktree must not replace the selected range's new-side blob.
printf 'worktree-only\n' >>"$repo3/f.txt"
rc="$(run_repo3 strict-range-content --fake-mode read-changed -- HEAD~1..HEAD)"
art="$( { ls "$repo3/artifacts"/kimi-strict-range-content-*.md 2>/dev/null || true; } | head -1)"
[[ "$rc" == "0" ]] && pass "strict-range-content: runner exit 0" || fail "strict-range-content: runner exit $rc"
if [[ -n "$art" ]]; then
  assert_contains "strict-range-content: selected new-side content" "$art" "v3"
  assert_not_contains "strict-range-content: dirty worktree excluded" "$art" "worktree-only"
else
  fail "strict-range-content: artifact missing"
fi
# ---------- case: outside-repo reads are denied and counted under strict scope ----------

printf 'OUTSIDE-PROBE-CONTENT-999\n' >"$work/outside-probe.txt"
rc="$(run_case strict-outside read-outside FAKE_OUTSIDE_PROBE="$work/outside-probe.txt" -- --slug strict-outside --artifact-dir "$repo/artifacts" --strict-scope)"
art="$(artifact_for strict-outside)"
[[ "$rc" == "0" ]] && pass "strict-outside: runner exit 0" || fail "strict-outside: runner exit $rc"
if [[ -n "$art" ]]; then
  assert_not_contains "strict-outside: probe content withheld" "$art" "OUTSIDE-PROBE-CONTENT-999"
  assert_contains "strict-outside: violation warning" "$art" "out-of-scope read attempt(s) were denied"
  assert_jq "strict-outside: violations counted" "${art%.md}.d/execution.json" '.scope_violation_attempts >= 1 and .scope_violation_events >= 1'
  assert_jq "strict-outside: not eligible" "${art%.md}.d/execution.json" '.gate_eligible == false and (.gate_ineligible_reasons | index("scope-violation-attempt") != null)'
  assert_not_contains "strict-outside: no global read allow" "${art%.md}.d/sandbox.sb" '(allow file-read*)'
else
  fail "strict-outside: artifact missing"
fi

# ---------- case: strict approved-path validation ----------

out="$work/strict-allow-broad.runner.log"
set +e
(cd "$repo" && env PATH="$bin:$PATH" KIMI_REVIEW_SKILL_DIR="$skill_dir" FAKE_KIMI_MODE=ok KIMI_REVIEW_STRICT_ALLOW_PATHS="$HOME" "$runner" --slug strict-allow-broad --artifact-dir "$repo/artifacts" --strict-scope) >"$out" 2>&1
rc=$?
set -e
[[ "$rc" == "2" ]] && pass "strict-allow: HOME rejected as too broad" || fail "strict-allow: broad path exit $rc (want 2)"
grep -q "too broad" "$out" && pass "strict-allow: broad rejection message" || fail "strict-allow: broad rejection message missing"

out="$work/strict-allow-cred.runner.log"
set +e
(cd "$repo" && env PATH="$bin:$PATH" KIMI_REVIEW_SKILL_DIR="$skill_dir" FAKE_KIMI_MODE=ok KIMI_REVIEW_STRICT_ALLOW_PATHS="$HOME/.ssh" "$runner" --slug strict-allow-cred --artifact-dir "$repo/artifacts" --strict-scope) >"$out" 2>&1
rc=$?
set -e
[[ "$rc" == "2" ]] && pass "strict-allow: credential path rejected" || fail "strict-allow: credential path exit $rc (want 2)"
grep -q "credential boundary" "$out" && pass "strict-allow: credential rejection message" || fail "strict-allow: credential rejection message missing"

# ---------- case: sanitized projection ----------

repo4="$work/repo4"
mkdir -p "$repo4"
git -C "$repo4" init -q
git -C "$repo4" config user.email test@example.com
git -C "$repo4" config user.name test
printf 'fixture v1\n' >"$repo4/fixture.txt"
git -C "$repo4" add .
git -C "$repo4" commit -qm c1
printf "token = 'sk-abcdefghij1234567890ab'\naws_key = 'AKIAIOSFODNN7EXAMPLE'\n" >>"$repo4/fixture.txt"

run_repo4() {
  local name="$1" mode="$2"; shift 2
  local out="$work/$name.runner.log"
  set +e
  (cd "$repo4" && env PATH="$bin:$PATH" KIMI_REVIEW_SKILL_DIR="$skill_dir" FAKE_KIMI_MODE="$mode" FAKE_REPO="$repo4" "$runner" --slug "$name" --artifact-dir "$repo4/artifacts" "$@") >"$out" 2>&1
  echo $?
  set -e
}

# original fixture content must still quarantine when it reaches the stream
rc="$(run_repo4 proj-quar read-fixture --strict-scope)"
art="$( { ls "$repo4/artifacts"/kimi-proj-quar-*.md 2>/dev/null || true; } | head -1)"
[[ "$rc" == "0" ]] && pass "proj-quar: runner exit 0" || fail "proj-quar: runner exit $rc"
if [[ -n "$art" ]]; then
  assert_contains "proj-quar: quarantine notice" "$art" "was quarantined"
  assert_not_contains "proj-quar: key not published" "$art" "AKIAIOSFODNN7EXAMPLE"
  assert_jq "proj-quar: not eligible" "${art%.md}.d/execution.json" '.gate_eligible == false and (.gate_ineligible_reasons | index("secret-quarantine") != null)'
else
  fail "proj-quar: artifact missing"
fi

# with --projection the review runs on the scrubbed copy and stays eligible
rc="$(run_repo4 projection read-projection --strict-scope --projection)"
art="$( { ls "$repo4/artifacts"/kimi-projection-*.md 2>/dev/null || true; } | head -1)"
[[ "$rc" == "0" ]] && pass "projection: runner exit 0" || fail "projection: runner exit $rc"
if [[ -n "$art" ]]; then
  assert_contains "projection: redacted placeholder reviewed" "$art" '[[REDACTED:sk-token]]'
  assert_not_contains "projection: key not in artifact" "$art" "AKIAIOSFODNN7EXAMPLE"
  assert_not_contains "projection: token not in artifact" "$art" "sk-abcdefghij1234567890ab"
  assert_contains "projection: review target noted" "$art" "- Review target: sanitized-projection"
  assert_contains "projection: verdict extracted" "$art" "- Verdict (heuristic): \`PASS\`"
  assert_contains "projection: manifest link" "$art" "- Projection manifest: \`./"
  assert_jq "projection: sidecar target" "${art%.md}.d/execution.json" '.review_target == "sanitized-projection"'
  assert_jq "projection: sidecar eligible" "${art%.md}.d/execution.json" '.gate_eligible == true and .scope_violation_attempts == 0 and .secret_scan.detected == false'
  assert_contains "projection: raw snapshot closed" "${art%.md}.d/sandbox.sb" '(deny file-read* (literal (param "RAW_SNAPSHOT")))'
  assert_not_contains "projection: originals not allowed" "${art%.md}.d/sandbox.sb" 'STRICT_FILE_'
  if [[ -f "${art%.md}.d/projection.json" ]]; then
    pass "projection: projection.json sidecar exists"
    assert_jq "projection: manifest mode" "${art%.md}.d/projection.json" '.mode == "sanitized-projection"'
    assert_jq "projection: fixture hashed" "${art%.md}.d/projection.json" '[.entries[] | select(.path == "fixture.txt")][0] | (.source_sha256 | length == 64) and (.projection_sha256 | length == 64) and .source_sha256 != .projection_sha256'
    assert_jq "projection: replacement rules recorded" "${art%.md}.d/projection.json" '[.entries[] | select(.path == "fixture.txt") | .replacements[] | .rule] | (index("sk-token") != null) and (index("aws-access-key") != null)'
    assert_jq "projection: snapshot entry recorded" "${art%.md}.d/projection.json" '[.entries[] | select(.path == "<diff-snapshot>")] | length == 1'
  else
    fail "projection: projection.json sidecar missing"
  fi
else
  fail "projection: artifact missing"
fi
grep -F 'jq -cn --arg path "$rel"' "$runner" >/dev/null \
  && pass "projection: manifest entries are compact JSONL" \
  || fail "projection: manifest entries are not compact JSONL"

# A denied read of the original snapshot must count against the strict gate.
rc="$(run_repo4 projection-raw projection-raw-read --strict-scope --projection --require-verdict)"
art="$( { ls "$repo4/artifacts"/kimi-projection-raw-*.md 2>/dev/null || true; } | head -1)"
[[ "$rc" == "4" ]] && pass "projection-raw: require-verdict exits 4" || fail "projection-raw: runner exit $rc (want 4)"
if [[ -n "$art" ]]; then
  assert_jq "projection-raw: violation counted" "${art%.md}.d/execution.json" '.scope_violation_attempts >= 1 and .scope_violation_events >= 1'
  assert_jq "projection-raw: gate ineligible" "${art%.md}.d/execution.json" '.gate_eligible == false and (.gate_ineligible_reasons | index("scope-violation-attempt") != null)'
else
  fail "projection-raw: artifact missing"
fi

# --projection without --strict-scope is rejected
out="$work/projection-nostrict.runner.log"
set +e
(cd "$repo4" && env PATH="$bin:$PATH" KIMI_REVIEW_SKILL_DIR="$skill_dir" FAKE_KIMI_MODE=ok "$runner" --slug projection-nostrict --artifact-dir "$repo4/artifacts" --projection) >"$out" 2>&1
rc=$?
set -e
[[ "$rc" == "2" ]] && pass "projection: requires --strict-scope" || fail "projection: no-strict exit $rc (want 2)"
grep -q -- "--projection requires --strict-scope" "$out" && pass "projection: no-strict rejection message" || fail "projection: no-strict rejection message missing"

# ---------- case: durable copy excludes quarantined raw streams ----------

rc="$(run_case durable-quar secret -- --slug durable-quar --artifact-dir "$repo/artifacts" --durable-dir "$repo/gate-quar")"
art="$(artifact_for durable-quar)"
[[ "$rc" == "0" ]] && pass "durable-quar: runner exit 0" || fail "durable-quar: runner exit $rc"
gate_art="$( { ls "$repo/gate-quar"/kimi-durable-quar-*.md 2>/dev/null || true; } | head -1)"
[[ -n "$gate_art" ]] && pass "durable-quar: gate markdown exists" || fail "durable-quar: gate markdown missing"
if [[ -n "$gate_art" ]]; then
  [[ -f "${gate_art%.md}.d/execution.json" ]] && pass "durable-quar: gate sidecar exists" || fail "durable-quar: gate sidecar missing"
  [[ -f "${gate_art%.md}.d/QUARANTINED.txt" ]] && pass "durable-quar: placeholder note exists" || fail "durable-quar: placeholder note missing"
  if ls "${gate_art%.md}.d/"*.quarantined.* >/dev/null 2>&1; then
    fail "durable-quar: quarantined raw stream copied to durable dir"
  else
    pass "durable-quar: no quarantined raw stream in durable dir"
  fi
  if grep -rq "AKIAIOSFODNN7EXAMPLE" "$repo/gate-quar" 2>/dev/null; then
    fail "durable-quar: secret literal reachable under durable dir"
  else
    pass "durable-quar: no secret literal under durable dir"
  fi
  assert_contains "durable-quar: exclusion noted" "$gate_art" "quarantined raw streams were excluded"
  assert_jq "durable-quar: gate still ineligible" "${gate_art%.md}.d/execution.json" '.gate_eligible == false and (.gate_ineligible_reasons | index("secret-quarantine") != null)'
fi
# the runtime sidecar still retains the raw evidence
if [[ -n "$art" && -f "${art%.md}.d/stdout.quarantined.jsonl" ]]; then
  pass "durable-quar: runtime sidecar retains quarantined raw"
else
  fail "durable-quar: runtime sidecar lost quarantined raw"
fi

# ---------- case: native watchdog enforces the outer timeout ----------

out="$work/timeout-native.runner.log"
set +e
start_s="$(date +%s)"
(cd "$repo" && env PATH="$bin:/usr/bin:/bin" KIMI_REVIEW_SKILL_DIR="$skill_dir" FAKE_KIMI_MODE=sleep FAKE_KIMI_SLEEP=60 KIMI_REVIEW_TIMEOUT_SECONDS=2 "$runner" --slug timeout-native --artifact-dir "$repo/artifacts") >"$out" 2>&1
rc=$?
set -e
elapsed_s=$(( $(date +%s) - start_s ))
art="$(artifact_for timeout-native)"
[[ "$rc" == "0" ]] && pass "timeout-native: runner exit 0" || fail "timeout-native: runner exit $rc"
[[ "$elapsed_s" -lt 30 ]] && pass "timeout-native: bounded wait (${elapsed_s}s < 30s)" || fail "timeout-native: waited ${elapsed_s}s (unbounded?)"
if [[ -n "$art" ]]; then
  assert_contains "timeout-native: status" "$art" "- Status: TIMED_OUT"
  assert_contains "timeout-native: timed_out flag" "$art" "- Timed out: \`true"
  assert_contains "timeout-native: watchdog recorded" "$art" "native bash watchdog"
else
  fail "timeout-native: artifact missing"
fi

# An external SIGKILL must not be mislabeled as the runner's timeout kill.
out="$work/self-kill-native.runner.log"
set +e
(cd "$repo" && env PATH="$bin:/usr/bin:/bin" KIMI_REVIEW_SKILL_DIR="$skill_dir" FAKE_KIMI_MODE=self-kill "$runner" --slug self-kill-native --artifact-dir "$repo/artifacts") >"$out" 2>&1
rc=$?
set -e
art="$(artifact_for self-kill-native)"
[[ "$rc" == "0" ]] && pass "self-kill-native: runner exit 0" || fail "self-kill-native: runner exit $rc"
if [[ -n "$art" ]]; then
  assert_contains "self-kill-native: failed status" "$art" "- Status: FAILED"
  assert_contains "self-kill-native: external signal" "$art" "SIGKILL (external)"
  assert_jq "self-kill-native: not timed out" "${art%.md}.d/execution.json" '.timed_out == false and .terminal_reason == "failed"'
else
  fail "self-kill-native: artifact missing"
fi

# ---------- case: in-scope text quoting denial phrases stays benign ----------

rc="$(run_case phrase phrase-fixture FAKE_REPO="$repo" -- --slug phrase --artifact-dir "$repo/artifacts" --strict-scope --require-verdict)"
art="$(artifact_for phrase)"
[[ "$rc" == "0" ]] && pass "phrase: runner exit 0 (gate eligible)" || fail "phrase: runner exit $rc"
if [[ -n "$art" ]]; then
  assert_contains "phrase: in-scope content reviewed" "$art" "Runbook excerpt"
  assert_jq "phrase: zero violations" "${art%.md}.d/execution.json" '.scope_violation_attempts == 0 and .scope_violation_events == 0'
  assert_jq "phrase: gate eligible" "${art%.md}.d/execution.json" '.gate_eligible == true'
else
  fail "phrase: artifact missing"
fi

# ---------- case: explicit slug cannot escape the artifact directory ----------

out="$work/slug-trav.runner.log"
set +e
(cd "$repo" && env PATH="$bin:$PATH" KIMI_REVIEW_SKILL_DIR="$skill_dir" FAKE_KIMI_MODE=ok "$runner" --slug 'x/../../escaped' --artifact-dir "$repo/artifacts") >"$out" 2>&1
rc=$?
set -e
[[ "$rc" == "2" ]] && pass "slug: traversal rejected" || fail "slug: traversal exit $rc (want 2)"
grep -q "Invalid --slug" "$out" && pass "slug: rejection message" || fail "slug: rejection message missing"
if find "$work" -name 'escaped*' -print -quit 2>/dev/null | grep -q .; then
  fail "slug: escaped artifact written outside artifact dir"
else
  pass "slug: no escaped artifact written"
fi

rc="$(run_case slug-ok ok -- --slug 'ok.name_1-2' --artifact-dir "$repo/artifacts")"
art="$(artifact_for 'ok.name_1-2')"
[[ "$rc" == "0" && -n "$art" ]] && pass "slug: allowlisted slug accepted" || fail "slug: allowlisted slug rc=$rc artifact=$art"

# ---------- case: explicit media is allowlisted under strict scope ----------

printf 'PNG-PROBE-CONTENT-111\n' >"$work/probe.png"
rc="$(run_case strict-media read-media FAKE_MEDIA_PATH="$work/probe.png" KIMI_REVIEW_MEDIA_PATHS="$work/probe.png" -- --slug strict-media --artifact-dir "$repo/artifacts" --strict-scope --require-verdict)"
art="$(artifact_for strict-media)"
[[ "$rc" == "0" ]] && pass "strict-media: runner exit 0 (gate eligible)" || fail "strict-media: runner exit $rc"
if [[ -n "$art" ]]; then
  assert_contains "strict-media: media content reviewed" "$art" "PNG-PROBE-CONTENT-111"
  assert_jq "strict-media: zero violations" "${art%.md}.d/execution.json" '.scope_violation_attempts == 0'
  assert_jq "strict-media: gate eligible" "${art%.md}.d/execution.json" '.gate_eligible == true'
else
  fail "strict-media: artifact missing"
fi

out="$work/strict-media-cred.runner.log"
set +e
(cd "$repo" && env PATH="$bin:$PATH" KIMI_REVIEW_SKILL_DIR="$skill_dir" FAKE_KIMI_MODE=ok KIMI_REVIEW_MEDIA_PATHS="$HOME/.ssh/fake.png" "$runner" --slug strict-media-cred --artifact-dir "$repo/artifacts" --strict-scope) >"$out" 2>&1
rc=$?
set -e
[[ "$rc" == "2" ]] && pass "strict-media: credential media path rejected" || fail "strict-media: credential media path exit $rc (want 2)"
grep -q "credential boundary" "$out" && pass "strict-media: credential rejection message" || fail "strict-media: credential rejection message missing"

# ---------- case: Git magic pathspecs are resolved by Git ----------

rc="$(run_case strict-magic ok -- --slug strict-magic --artifact-dir "$repo/artifacts" --strict-scope -- ':(icase)F.TXT')"
[[ "$rc" == "0" ]] && pass "strict-magic: icase pathspec accepted" || fail "strict-magic: icase pathspec exit $rc"

rc="$(run_case strict-glob ok -- --slug strict-glob --artifact-dir "$repo/artifacts" --strict-scope -- ':(glob)**/f.txt')"
[[ "$rc" == "0" ]] && pass "strict-magic: glob pathspec accepted" || fail "strict-magic: glob pathspec exit $rc"

out="$work/strict-magic-bad.runner.log"
set +e
(cd "$repo" && env PATH="$bin:$PATH" KIMI_REVIEW_SKILL_DIR="$skill_dir" FAKE_KIMI_MODE=ok "$runner" --slug strict-magic-bad --artifact-dir "$repo/artifacts" --strict-scope -- ':(icase)NOPE.TXT') >"$out" 2>&1
rc=$?
set -e
[[ "$rc" == "2" ]] && pass "strict-magic: unmatched magic pathspec rejected" || fail "strict-magic: unmatched magic pathspec exit $rc (want 2)"
grep -q "has no changes in the selected diff" "$out" && pass "strict-magic: rejection message" || fail "strict-magic: rejection message missing"

# ---------- summary ----------

echo
if [[ "$failures" -eq 0 ]]; then
  printf 'All run_review tests passed.\n'
  exit 0
else
  printf '%d run_review test(s) FAILED.\n' "$failures" >&2
  exit 1
fi
