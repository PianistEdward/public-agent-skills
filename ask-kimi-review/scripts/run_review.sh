#!/usr/bin/env bash
# run_review.sh - single, non-bypassable entry point for ask-kimi-review.
#
# Encapsulates the full execution contract: scope/diff pairing, model
# resolution, macOS sandbox, outer timeout, interrupt-safe artifact,
# structured execution record, mutation/process evidence, secret
# quarantine, and verified cleanup. Callers pass scope + diff args only;
# do not hand-roll stripped-down kimi invocations.
#
# Usage:
#   run_review.sh [--scope TEXT] [--slug NAME] [--model ID]
#                 [--artifact-dir DIR] [--durable-dir DIR]
#                 [--timeout-seconds N] [--strict-scope] [--projection]
#                 [--require-verdict] [-- DIFF_ARGS...]
#
# Examples:
#   run_review.sh                                        # git diff
#   run_review.sh --scope "git diff --cached" -- --cached
#   run_review.sh --scope "git diff main..HEAD" -- main..HEAD
#   run_review.sh --scope "git diff -- src/a" -- -- src/a
#
# Env overrides: KIMI_REVIEW_MODEL, KIMI_REVIEW_SLUG, KIMI_REVIEW_ARTIFACT_DIR,
# KIMI_REVIEW_DURABLE_DIR, KIMI_REVIEW_TIMEOUT_SECONDS (default 1800),
# KIMI_REVIEW_MEDIA_PATHS, KIMI_REVIEW_SKILL_DIR, KIMI_REVIEW_KIMI_HOME,
# KIMI_REVIEW_STRICT_SCOPE, KIMI_REVIEW_STRICT_ALLOW_PATHS,
# KIMI_REVIEW_PROJECTION, KIMI_REVIEW_REQUIRE_VERDICT,
# KIMI_REVIEW_PROVIDER_TIMEOUT_SECONDS (default 30).
#
# Runner exit codes: 0 = artifact finalized (review outcome is recorded
# inside the artifact, including non-zero review exit, timeout, or empty
# output); 2 = model resolution failed; 3 = precondition/internal failure.
# A review that is interrupted by signal still finalizes an INTERRUPTED
# artifact before the runner exits 128+signal.

set -u
RUNNER_VERSION="1.6.9"

# ---------- argument parsing ----------

scope="${KIMI_REVIEW_SCOPE:-}"
scope_explicit=0
[[ -n "$scope" ]] && scope_explicit=1
slug="${KIMI_REVIEW_SLUG:-}"
requested_model="${KIMI_REVIEW_MODEL:-kimi-for-coding}"
artifact_dir="${KIMI_REVIEW_ARTIFACT_DIR:-}"
durable_dir="${KIMI_REVIEW_DURABLE_DIR:-}"
timeout_seconds="${KIMI_REVIEW_TIMEOUT_SECONDS:-1800}"
strict_scope="${KIMI_REVIEW_STRICT_SCOPE:-0}"
require_verdict="${KIMI_REVIEW_REQUIRE_VERDICT:-0}"
projection="${KIMI_REVIEW_PROJECTION:-0}"
diff_args=()
diff_cached=0
diff_new_tree=""

usage() {
  cat <<'USAGE'
Usage: run_review.sh [--scope TEXT] [--slug NAME] [--model ID]
                     [--artifact-dir DIR] [--durable-dir DIR]
                     [--timeout-seconds N] [--strict-scope] [--projection]
                     [--require-verdict] [-- DIFF_ARGS...]

Examples:
  run_review.sh                                        # git diff
  run_review.sh -- --cached                            # scope text is derived
  run_review.sh --scope "git diff main..HEAD" -- main..HEAD
  run_review.sh --scope "git diff -- src/a" -- -- src/a

--scope TEXT      display label for the review scope; must tokenize to exactly
                  "git diff" plus the DIFF_ARGS, otherwise the run is rejected.
                  Omit it to let the runner derive the canonical scope text.

--strict-scope    deny-by-default file reads for Kimi: only the diff snapshot,
                  changed files, KIMI_REVIEW_STRICT_ALLOW_PATHS entries, the
                  Kimi runtime, and system paths are readable
--projection      with --strict-scope: review a sanitized projection of the
                  snapshot and changed files (secret-shaped literals replaced
                  by [[REDACTED:<rule>]] placeholders); source/projection
                  SHA-256 and replacement counts are recorded in projection.json
--require-verdict exit 4 unless the finalized artifact is gate-eligible
USAGE
  exit "${1:-2}"
}

while (( $# > 0 )); do
  case "$1" in
    --scope)            scope="${2:?--scope needs a value}"; scope_explicit=1; shift 2 ;;
    --slug)             slug="${2:?--slug needs a value}"; shift 2 ;;
    --model)            requested_model="${2:?--model needs a value}"; shift 2 ;;
    --artifact-dir)     artifact_dir="${2:?--artifact-dir needs a value}"; shift 2 ;;
    --durable-dir)      durable_dir="${2:?--durable-dir needs a value}"; shift 2 ;;
    --timeout-seconds)  timeout_seconds="${2:?--timeout-seconds needs a value}"; shift 2 ;;
    --strict-scope)     strict_scope=1; shift ;;
    --projection)       projection=1; shift ;;
    --require-verdict)  require_verdict=1; shift ;;
    --help|-h)          usage 0 ;;
    --)                 shift; while (( $# > 0 )); do diff_args+=("$1"); shift; done ;;
    *)                  printf 'Unknown argument: %s\n' "$1" >&2; usage 2 ;;
  esac
done

if [[ ! "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
  printf 'Invalid --timeout-seconds: %s\n' "$timeout_seconds" >&2
  exit 2
fi

if [[ "$projection" == "1" && "$strict_scope" != "1" ]]; then
  printf '%s\n' '--projection requires --strict-scope: only the strict boundary can keep the original files out of the review stream.' >&2
  exit 2
fi

# The scope text and the diff arguments must describe the same review.
# Default: derive the canonical scope string from the diff arguments.
# Explicit --scope: accept only when it tokenizes to exactly that string.
canonical_scope="git diff"
for _diff_arg in ${diff_args[@]+"${diff_args[@]}"}; do
  canonical_scope="$canonical_scope $_diff_arg"
done
if [[ "$scope_explicit" == "1" ]]; then
  scope_tokens=($scope)
  canonical_tokens=($canonical_scope)
  if [[ "${scope_tokens[*]}" != "${canonical_tokens[*]}" ]]; then
    printf 'Scope text does not match the diff arguments.\n  given:    %s\n  canonical: %s\n' "$scope" "$canonical_scope" >&2
    exit 2
  fi
else
  scope="$canonical_scope"
fi

# Identify the content source for strict-scope materialization. A range must
# be reviewed from its selected new side, and a staged review from the index;
# only an ordinary worktree diff may use the current file contents.
_after_ddash=0
for _diff_arg in ${diff_args[@]+"${diff_args[@]}"}; do
  if [[ "$_diff_arg" == "--" ]]; then
    _after_ddash=1
    continue
  fi
  [[ "$_after_ddash" == "1" ]] && continue
  [[ "$_diff_arg" == "--cached" || "$_diff_arg" == "--staged" ]] && diff_cached=1
  if [[ -z "$diff_new_tree" && "$_diff_arg" == *...* ]]; then
    diff_new_tree="${_diff_arg##*...}"
  elif [[ -z "$diff_new_tree" && "$_diff_arg" == *..* ]]; then
    diff_new_tree="${_diff_arg##*..}"
  fi
done

# ---------- setup ----------

# Self-locate the skill directory so the skill works from any agent home
# (~/.agents/skills, ~/.codex/skills via a directory symlink, or any other
# install root). KIMI_REVIEW_SKILL_DIR remains available as an explicit
# override. Symlink the skill DIRECTORY, not individual files: BASH_SOURCE
# resolves through the directory link, but not through a link placed on the
# script file itself.
if [[ -n "${KIMI_REVIEW_SKILL_DIR:-}" ]]; then
  skill_dir="$KIMI_REVIEW_SKILL_DIR"
else
  skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)" ||
    { printf 'run_review: cannot resolve skill directory from %s\n' "${BASH_SOURCE[0]}" >&2; exit 64; }
fi
kimi_home="${KIMI_REVIEW_KIMI_HOME:-$HOME/.kimi-code}"
media_paths="${KIMI_REVIEW_MEDIA_PATHS:-}"
media_scope="none"
if [[ -z "$slug" ]]; then
  slug="$(printf '%s' "$scope" | tr -cs '[:alnum:]_.-' '-' | cut -c1-60)"
fi
slug="${slug:-current-diff}"
# The slug becomes a filename component of the artifact and sidecar paths.
# Restrict it to a bounded allowlist so an explicit --slug can never write
# outside --artifact-dir (no separators, no traversal sequences).
if [[ ! "$slug" =~ ^[A-Za-z0-9._-]{1,60}$ || "$slug" == *..* ]]; then
  printf 'Invalid --slug: %s (use 1-60 characters from [A-Za-z0-9._-]; no path separators or "..")\n' "$slug" >&2
  exit 2
fi
tmp_dir="${TMPDIR:-/tmp}"
if ! tmp_dir="$(cd "$tmp_dir" 2>/dev/null && pwd -P)"; then
  printf 'Unable to resolve TMPDIR to a real writable path.\n' >&2
  exit 3
fi
# Every runner/review temporary file lives in one per-run directory so the
# strict sandbox can allow exactly this directory instead of all of TMPDIR.
# mktemp returns the /var/folders symlink form; the sandbox matches
# kernel-resolved paths, so canonicalize before it becomes a -D parameter.
run_tmp=""
if ! run_tmp="$(mktemp -d -t kimi-review-run.XXXXXX)"; then
  printf 'Unable to create the per-run temporary directory.\n' >&2
  exit 3
fi
if ! run_tmp="$(cd "$run_tmp" 2>/dev/null && pwd -P)"; then
  printf 'Unable to resolve the per-run temporary directory.\n' >&2
  exit 3
fi
sandbox_profile=""
diff_snapshot=""
prompt_snapshot=""
raw_out=""
raw_err=""
prompt=""
review_processes=""
review_pid=""
monitor_pid=""
watchdog_pid=""
native_timeout_fired=0
artifact=""
artifact_created=0
finalized=0
quarantined_files=""
pgrep_path="$(command -v pgrep 2>/dev/null || true)"
provider_timeout_seconds="${KIMI_REVIEW_PROVIDER_TIMEOUT_SECONDS:-30}"
if [[ ! "$provider_timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
  provider_timeout_seconds=30
fi

# Gate/sidecar state (finalized during append_evidence_and_cleanup).
scope_mode="open"
review_target="original"
projection_dir=""
projection_manifest=""
scope_violation_attempts=0
empty_output=0
secret_detected_bool=false
mutation_detected_bool=false
mutation_changed=""
gate_eligible=false
gate_reasons=("review-in-progress")
terminal_reason="running"
session_id=""
finished_at=""
final_exit_code=""
final_timed_out=""
final_signal=""
duration_ms_disp=""
process_release=""
temporary_release=""
after_head=""
before_head=""
started_at=""
start_ms=""
end_ms=""
after_review=""
before_worktree_fp=""
before_staged_fp=""
after_worktree_fp=""
after_staged_fp=""
secret_scan_failed=false
secret_sources=""
remaining_pids=""
mismatch_pids=""
remaining_review_processes=""
provider_error=""
runner_internal=""
violation_events=0
violation_stderr_hits=0
violation_log_hits=0
strict_cwd=""
strict_allowed_paths=()
strict_denied_paths=()
final_verdict=""
verdict_contract="none"

die() {
  printf '%s\n' "$1" >&2
  exit "${2:-3}"
}

now_ms() {
  # ServBay can shadow `python3` with a project-discovery shell wrapper. A
  # hung wrapper must not orphan a runner child, so prefer the system Perl
  # implementation for this tiny clock read before PATH-resolved fallbacks.
  if [[ -x /usr/bin/perl ]]; then
    /usr/bin/perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000' 2>/dev/null && return 0
  fi
  python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null && return 0
  perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000' 2>/dev/null && return 0
  printf '%s000\n' "$(date +%s)"
}

# Portable SHA-256 (macOS shasum, Linux sha256sum).
hash_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

hash_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

canonical_dir() {
  local path="$1" resolved=""
  if [[ -d "$path" ]] && resolved="$(cd "$path" 2>/dev/null && pwd -P)" && [[ -n "$resolved" ]]; then
    printf '%s\n' "$resolved"
  else
    printf '%s\n' "$path"
  fi
}

# Materialize the exact selected-side content for one changed path. This keeps
# strict reviews independent from a concurrently dirty worktree. Deleted paths
# are skipped by callers because there is no readable new-side file.
materialize_selected_file() {
  local rel="$1" dst="$2" parent
  parent="$(dirname "$dst")"
  mkdir -p "$parent" || return 1
  if [[ "$diff_cached" == "1" ]]; then
    git show ":$rel" >"$dst" 2>/dev/null
  elif [[ -n "$diff_new_tree" ]]; then
    git show "$diff_new_tree:$rel" >"$dst" 2>/dev/null
  else
    # NEVER dereference a symlink — not the final component and not an
    # intermediate one: `-f` is true through parent links and `cp` follows
    # them, so `foo/id_rsa` with `foo -> ~/.ssh` would copy the TARGET content
    # into the review stream, outside every credential boundary. Materialize
    # the resolved-path text instead, and never cp a path that resolves
    # elsewhere than its literal spelling.
    _src="$repo_root/$rel"
    _src_real="$(rp_path "$_src")"
    if [[ -L "$_src" || "$_src_real" != "$_src" ]]; then
      printf 'symlink-path -> %s\n' "$_src_real" >"$dst"
      return 0
    fi
    [[ -f "$_src" ]] || return 1
    cp "$_src" "$dst"
  fi
}

# True when $1 is a credential boundary path or lives underneath one. The
# boundary list is assigned near the sandbox setup (it needs $codex_dir).
path_overlaps_boundary() {
  local p="$1" b
  for b in ${credential_boundaries[@]+"${credential_boundaries[@]}"}; do
    # both directions: a path inside a boundary, OR an ancestor of one
    # (naming a parent like ~/.config would otherwise re-allow its children
    # through the allow rule appended after the credential denies)
    case "$p" in
      "$b"|"$b"/*) return 0 ;;
    esac
    case "$b" in
      "$p"|"$p"/*) return 0 ;;
    esac
  done
  return 1
}

# Copies $2 (label $4) to $3, replacing every secret-pattern match with a
# [[REDACTED:<rule>]] placeholder, and appends one JSON entry (source and
# projection SHA-256, per-rule replacement counts) to $projection_manifest.
# Binary files are copied verbatim; perl scrubbing would corrupt them and the
# text patterns cannot match them meaningfully.
scrub_projection_file() {
  local src="$1" dst="$2" rel="$3" handling="scrubbed" repl_json="[]"
  local src_sha="" dst_sha="" name="" pattern="" count=""
  [[ -f "$src" ]] || return 1
  src_sha="$(hash_file "$src")"
  mkdir -p "$(dirname "$dst")" || return 1
  cp "$src" "$dst" || return 1
  if [[ ! -s "$src" ]] || grep -Iq . "$src" 2>/dev/null; then
    while IFS='|' read -r name pattern; do
      [[ -n "$name" ]] || continue
      count="$(SCRUB_PATTERN="$pattern" perl -0777 -ne '$c += () = m/$ENV{SCRUB_PATTERN}/gi; END { print $c + 0 }' "$dst" 2>/dev/null)"
      [[ "$count" =~ ^[0-9]+$ ]] || count=0
      if [[ "$count" -gt 0 ]]; then
        repl_json="$(jq --arg n "$name" --argjson c "$count" '. + [{rule:$n,count:$c}]' <<<"$repl_json")" || return 1
        SCRUB_PATTERN="$pattern" SCRUB_NAME="$name" perl -0777 -pi -e 's{$ENV{SCRUB_PATTERN}}{"[[" . "REDACTED:" . $ENV{SCRUB_NAME} . "]]"}gie' "$dst" || return 1
      fi
    done < <(secret_patterns)
  else
    handling="verbatim-binary"
  fi
  dst_sha="$(hash_file "$dst")"
  jq -cn --arg path "$rel" --arg s "$src_sha" --arg p "$dst_sha" --arg h "$handling" --argjson r "$repl_json" \
    '{path:$path,source_sha256:$s,projection_sha256:$p,handling:$h,replacements:$r}' >>"$projection_manifest"
}

read_provider_catalog() {
  local timeout_command=()
  if gtimeout_path="$(command -v gtimeout 2>/dev/null)"; then
    timeout_command=("$gtimeout_path" -k 5s "$provider_timeout_seconds")
  elif timeout_path="$(command -v timeout 2>/dev/null)"; then
    timeout_command=("$timeout_path" -k 5s "$provider_timeout_seconds")
  fi
  if (( ${#timeout_command[@]} > 0 )); then
    "${timeout_command[@]}" kimi provider list --json
  else
    kimi provider list --json
  fi
}

# Process diagnostics are limited to pid/ppid/pgid/elapsed/state/comm.
# Never print full environments or argv (they may carry secrets).
# Process identity distinguishes a live tracked process from a reused PID.
# Start time + command name survive reparenting; a changed value means reuse.
# ps exit 1 means the process exited after discovery; >=2 means ps itself failed.
process_identity() {
  local pid="$1" ps_output ps_status identity
  ps_output="$(ps -p "$pid" -o lstart=,comm= 2>/dev/null)"
  ps_status=$?
  if [[ "$ps_status" -eq 1 ]]; then
    return 1
  elif [[ "$ps_status" -ne 0 ]]; then
    return 2
  fi
  identity="$(printf '%s\n' "$ps_output" | awk 'NF {$1=$1; print; exit}')"
  [[ -n "$identity" ]] || return 1
  printf '%s\n' "$identity"
}

record_review_tree() {
  local parent="$1" child identity
  if identity="$(process_identity "$parent")"; then
    if ! awk -v p="$parent" '$1 == p { f=1 } END { exit !f }' "$review_processes" 2>/dev/null; then
      printf '%s\t%s\n' "$parent" "$identity" >>"$review_processes"
    fi
  fi
  [[ -n "$pgrep_path" ]] || return 0
  while IFS= read -r child; do
    [[ -n "$child" ]] && record_review_tree "$child"
  done < <("$pgrep_path" -P "$parent" 2>/dev/null || true)
}

monitor_review_tree() {
  while kill -0 "$1" 2>/dev/null; do
    record_review_tree "$1"
    sleep 0.2
  done
}

terminate_review_tree() {
  local parent="$1" signal="$2" child
  if [[ -n "$pgrep_path" ]]; then
    while IFS= read -r child; do
      [[ -n "$child" ]] && terminate_review_tree "$child" "$signal"
    done < <("$pgrep_path" -P "$parent" 2>/dev/null || true)
  fi
  kill "-$signal" "$parent" 2>/dev/null || true
}

stop_review_processes() {
  if [[ -n "$watchdog_pid" ]] && kill -0 "$watchdog_pid" 2>/dev/null; then
    kill -TERM "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
  fi
  watchdog_pid=""
  if [[ -n "$monitor_pid" ]] && kill -0 "$monitor_pid" 2>/dev/null; then
    kill -TERM "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
  fi
  monitor_pid=""
  if [[ -n "$review_pid" ]] && kill -0 "$review_pid" 2>/dev/null; then
    terminate_review_tree "$review_pid" TERM
    sleep 1
    if kill -0 "$review_pid" 2>/dev/null; then
      terminate_review_tree "$review_pid" KILL
    fi
    wait "$review_pid" 2>/dev/null || true
  fi
}

remove_temp_files() {
  local temp_path
  for temp_path in "$raw_out" "$raw_err" "$prompt" "$diff_snapshot"; do
    if [[ -n "$temp_path" && -e "$temp_path" ]]; then
      case " $quarantined_files " in
        *" $temp_path "*) : ;;  # quarantined raw files are retained as evidence
        *) unlink "$temp_path" 2>/dev/null || true ;;
      esac
    fi
  done
  if [[ -n "$strict_cwd" && -d "$strict_cwd" ]]; then
    rm -rf "$strict_cwd" 2>/dev/null || true
  fi
  if [[ -n "$run_tmp" && -d "$run_tmp" ]]; then
    rm -rf "$run_tmp" 2>/dev/null || true
  fi
}

# ---------- secret quarantine ----------

# Single source of truth for secret patterns, shared by the output scanner
# and the projection scrubber. Format: <rule-name>|<ERE pattern>, one per line.
secret_patterns() {
  cat <<'SECRET_PATTERNS'
aws-access-key|(^|[^[:alnum:]_])AKIA[0-9A-Z]{16}
private-key-block|BEGIN [A-Z ]*PRIVATE KEY
sk-token|(^|[^[:alnum:]_])sk-[A-Za-z0-9_-]{20}
github-token|(^|[^[:alnum:]_])gh[pousr]_[A-Za-z0-9]{20}
gitlab-token|(^|[^[:alnum:]_])glpat-[A-Za-z0-9_-]{20}
slack-token|(^|[^[:alnum:]_])xox[baprs]-[A-Za-z0-9-]{10}
bearer-token|Bearer [A-Za-z0-9._~-]{20}
credential-assignment|(api[_-]?key|secret|token)[[:space:]]*[:=][[:space:]]*["']?[A-Za-z0-9_/+-]{16}
SECRET_PATTERNS
}

# Prints matched pattern names, one per line. Raw output that matches is
# never copied into the durable artifact; the raw file is retained instead.
scan_secrets() {
  local file="$1" name pattern rc=0 grep_rc
  [[ -f "$file" ]] || return 0
  while IFS='|' read -r name pattern; do
    [[ -n "$name" ]] || continue
    grep -Eiq -e "$pattern" "$file" 2>/dev/null
    grep_rc=$?
    if [[ "$grep_rc" -eq 0 ]]; then
      printf '%s\n' "$name"
    elif [[ "$grep_rc" -ge 2 ]]; then
      rc=2
    fi
  done < <(secret_patterns)
  return "$rc"
}

# Writes the machine-readable gate record at <artifact>.d/execution.json.
# Callers set the globals listed in the jq arguments below; gate_reasons is a
# bash array of non-sensitive ineligibility reasons.
write_execution_json() {
  local record_status="$1" reasons_json rules_json changed_json
  local sampled_json remaining_json mismatch_json sources_json
  local duration_ms_json="null" timed_out_json=false failure_reason=""
  case "$record_status" in
    COMPLETED)    terminal_reason="completed" ;;
    TIMED_OUT)    terminal_reason="timeout" ;;
    INTERRUPTED*) terminal_reason="interrupted" ;;
    FAILED*)      terminal_reason="failed" ;;
    *)            terminal_reason="running" ;;
  esac
  reasons_json="$(printf '%s\n' "${gate_reasons[@]+"${gate_reasons[@]}"}" | jq -Rn '[inputs | select(length > 0)]')"
  rules_json="$(printf '%s\n' "${secret_hits:-}" | jq -Rn '[inputs | select(length > 0)]')"
  changed_json="$(printf '%s\n' "$mutation_changed" | jq -Rn '[inputs | select(length > 0)]')"
  sources_json="$(printf '%s\n' $secret_sources | jq -Rn '[inputs | select(length > 0)]')"
  diff_args_json="$(for _diff_arg in ${diff_args[@]+"${diff_args[@]}"}; do printf '%s\n' "$_diff_arg"; done | jq -Rn '[inputs]')"
  sampled_json="$(awk '$1 ~ /^[0-9]+$/ {print $1}' "$review_processes" 2>/dev/null | sort -un | jq -Rn '[inputs | select(length > 0) | tonumber]')"
  remaining_json="$(printf '%s\n' $remaining_review_processes | jq -Rn '[inputs | select(length > 0) | tonumber]')"
  mismatch_json="$(printf '%s\n' $mismatch_pids | jq -Rn '[inputs | select(length > 0) | tonumber]')"
  if [[ "$start_ms" =~ ^[0-9]+$ && "$end_ms" =~ ^[0-9]+$ ]]; then
    duration_ms_json=$(( end_ms - start_ms ))
  fi
  [[ "$final_timed_out" != "false" && -n "$final_timed_out" ]] && timed_out_json=true
  [[ "$gate_eligible" != "true" ]] && failure_reason="${gate_reasons[0]:-}"
  jq -n \
    --arg runner_version "$RUNNER_VERSION" \
    --arg status "$record_status" \
    --arg terminal_reason "$terminal_reason" \
    --argjson gate_eligible "$gate_eligible" \
    --argjson gate_ineligible_reasons "$reasons_json" \
    --arg failure_reason "$failure_reason" \
    --arg artifact_class "$evidence_class" \
    --arg scope "$scope" \
    --arg verdict "$final_verdict" \
    --arg verdict_contract "$verdict_contract" \
    --arg model "$model" \
    --arg provider_identity "$provider_identity" \
    --arg kimi_session "$session_id" \
    --arg started_at "$started_at" \
    --arg finished_at "$finished_at" \
    --argjson started_at_epoch_ms "${start_ms:-null}" \
    --argjson finished_at_epoch_ms "${end_ms:-null}" \
    --argjson duration_ms "$duration_ms_json" \
    --arg duration_precision "milliseconds" \
    --arg exit_code "$final_exit_code" \
    --argjson timed_out "$timed_out_json" \
    --arg termination_signal "$final_signal" \
    --arg timeout_policy "outer ${timeout_seconds}s (kill-after 5s); provider catalog ${provider_timeout_seconds}s" \
    --arg isolation "$isolation" \
    --arg scope_mode "$scope_mode" \
    --arg review_target "$review_target" \
    --argjson scope_violation_attempts "$scope_violation_attempts" \
    --argjson scope_violation_events "${violation_events:-0}" \
    --argjson scope_violation_log_hits "${violation_log_hits:-0}" \
    --arg visual_preflight "$visual_preflight" \
    --arg snapshot_sha256 "${snapshot_sha:-unavailable}" \
    --argjson secret_detected "$secret_detected_bool" \
    --argjson secret_scan_failed "$secret_scan_failed" \
    --argjson secret_sources "$sources_json" \
    --argjson secret_rules "$rules_json" \
    --argjson mutation_detected "$mutation_detected_bool" \
    --arg head_before "$before_head" \
    --arg head_after "$after_head" \
    --argjson mutation_changed "$changed_json" \
    --arg process_release "$process_release" \
    --arg temporary_release "$temporary_release" \
    --argjson sampled_pids "$sampled_json" \
    --argjson remaining_pids "$remaining_json" \
    --argjson identity_mismatch_pids "$mismatch_json" \
    --arg artifact "$artifact" \
    --argjson diff_args "$diff_args_json" \
    --arg snapshot_path "$diff_snapshot" \
    '{runner_version:$runner_version,status:$status,terminal_reason:$terminal_reason,gate_eligible:$gate_eligible,gate_ineligible_reasons:$gate_ineligible_reasons,failure_reason:(if $failure_reason == "" then null else $failure_reason end),artifact_class:$artifact_class,scope:$scope,verdict:(if $verdict == "" then null else $verdict end),verdict_contract:$verdict_contract,diff_args:$diff_args,snapshot_path:$snapshot_path,model:$model,provider_identity:$provider_identity,kimi_session:$kimi_session,started_at:$started_at,finished_at:$finished_at,started_at_epoch_ms:$started_at_epoch_ms,finished_at_epoch_ms:$finished_at_epoch_ms,duration_ms:$duration_ms,duration_precision:$duration_precision,exit_code:$exit_code,timed_out:$timed_out,termination_signal:$termination_signal,timeout_policy:$timeout_policy,isolation:$isolation,scope_mode:$scope_mode,review_target:$review_target,scope_violation_attempts:$scope_violation_attempts,scope_violation_events:$scope_violation_events,scope_violation_log_hits:$scope_violation_log_hits,visual_preflight:$visual_preflight,snapshot_sha256:$snapshot_sha256,secret_scan:{detected:$secret_detected,scan_failed:$secret_scan_failed,sources:$secret_sources,rules:$secret_rules},mutation:{detected:$mutation_detected,head_before:$head_before,head_after:$head_after,changed:$mutation_changed},resources:{sampled_pids:$sampled_pids,remaining_pids:$remaining_pids,identity_mismatch_pids:$identity_mismatch_pids},process_release:$process_release,temporary_release:$temporary_release,artifact:$artifact}' \
    >"$sidecar_dir/execution.json"
}

# ---------- preconditions ----------

# Clean up any temporary files created so far on early failure exits.
trap remove_temp_files EXIT

command -v kimi >/dev/null 2>&1 || die 'Kimi Code CLI is not installed or not on PATH.' 2
command -v jq >/dev/null 2>&1 || die 'jq is required; install jq before running a review.' 2

if ! model="$("$skill_dir/scripts/resolve_model.sh" "$requested_model")" || [[ -z "$model" ]]; then
  die "Unable to resolve requested Kimi model: $requested_model" 2
fi
if ! repo_root="$(git rev-parse --show-toplevel)" || [[ -z "$repo_root" ]]; then
  die 'Review must run inside a git repository.' 3
fi
repo_root="$(canonical_dir "$repo_root")"
if ! git_dir="$(git rev-parse --absolute-git-dir)" || [[ -z "$git_dir" ]]; then
  die 'Unable to resolve the repository git directory.' 3
fi
git_dir="$(canonical_dir "$git_dir")"
skill_dir="$(canonical_dir "$skill_dir")"
kimi_home="$(canonical_dir "$kimi_home")"
rp_path() { /usr/bin/perl -MCwd=realpath -e 'print(realpath($ARGV[0]) // $ARGV[0])' "$1" 2>/dev/null || printf '%s' "$1"; }

# canonicalization availability: without a usable perl the realpath step
# falls back to raw spellings, which SBPL treats as inert — surface it
# instead of silently reverting to the pre-fix behaviour
canon_unavailable=0
[[ -x /usr/bin/perl ]] || canon_unavailable=1
canon_note=""
[[ "$canon_unavailable" == 1 ]] && canon_note="; WARNING path canonicalization unavailable (perl missing): symlink-sensitive denies may be inert"
codex_dir="$(canonical_dir "${CODEX_HOME:-$HOME/.codex}")"
# P3-4 hardening: the credential boundary must cover the literal $HOME/.codex
# even when CODEX_HOME points elsewhere, so a non-Codex host exporting
# CODEX_HOME for its own tooling cannot move the deny boundary away from the
# real Codex CLI credentials.
codex_default_dir=""
if [[ -d "$HOME/.codex" && "$HOME/.codex" != "${CODEX_HOME:-$HOME/.codex}" ]]; then
  codex_default_dir="$(canonical_dir "$HOME/.codex")"
fi
# Credential read boundaries, kept in sync with the -D parameters passed to
# sandbox-exec below. Strict scope validates changed/approved paths against
# this list before it appends any allow rule.
credential_boundaries=(
  "$(rp_path "$HOME/.ssh")" "$(rp_path "$HOME/.aws")" "$(rp_path "$HOME/.gnupg")" "$(rp_path "$HOME/.config/gh")" "$(rp_path "$codex_dir")"
  "$(rp_path "$HOME/.kube")" "$(rp_path "$HOME/.docker")" "$(rp_path "$HOME/.azure")" "$(rp_path "$HOME/.config/gcloud")"
  "$(rp_path "$HOME/.git-credentials")" "$(rp_path "$HOME/.config/git/credentials")" "$(rp_path "$HOME/.netrc")"
  "$(rp_path "$HOME/.npmrc")" "$(rp_path "$HOME/.yarnrc.yml")" "$(rp_path "$HOME/.config/pip")" "$(rp_path "$HOME/.bundle")"
  "$(rp_path "$HOME/.terraform.d")" "$(rp_path "$HOME/.claude")" "$(rp_path "$HOME/.pypirc")"
  "$(rp_path "$HOME/.pip/pip.conf")" "$(rp_path "$HOME/.bundle/config")" "$(rp_path "$HOME/.gem/credentials")"
  "$(rp_path "$HOME/.m2/settings.xml")" "$(rp_path "$HOME/.gradle/gradle.properties")"
  "$(rp_path "$HOME/.cargo/credentials.toml")" "$(rp_path "$HOME/.composer/auth.json")"
  "$(rp_path "$HOME/.terraform.d/credentials.tfrc.json")"
)
if [[ -n "$codex_default_dir" ]]; then
  credential_boundaries+=("$codex_default_dir")
fi
if [[ "$strict_scope" == "1" ]]; then
  # strict mode closes the .git object database entirely, so the fallback
  # snapshot must live outside the git directory (in the per-run temporary
  # directory, which the sandbox permits) instead of being write-protected
  # inside it
  if ! diff_snapshot="$(mktemp "$run_tmp/kimi-review-diff.XXXXXX")"; then
    die 'Unable to create the fallback diff snapshot.' 3
  fi
elif ! diff_snapshot="$(mktemp "$git_dir/kimi-review-diff.XXXXXX")"; then
  die 'Unable to create the write-protected diff snapshot.' 3
fi
if ! git -c diff.external= -c diff.relative=false diff --no-ext-diff --no-textconv ${diff_args[@]+"${diff_args[@]}"} >"$diff_snapshot"; then
  die 'Unable to capture the requested git diff.' 3
fi
snapshot_sha="$(hash_file "$diff_snapshot")"
prompt_snapshot="$diff_snapshot"
if ! raw_out="$(mktemp "$run_tmp/kimi-review-out.XXXXXX")" ||
  ! raw_err="$(mktemp "$run_tmp/kimi-review-err.XXXXXX")" ||
  ! prompt="$(mktemp "$run_tmp/kimi-review-prompt.XXXXXX")"
then
  die 'Unable to create review temporary files.' 3
fi
if [[ -z "$artifact_dir" ]]; then
  artifact_dir="$repo_root/.omx/artifacts"
fi
if ! mkdir -p "$artifact_dir"; then
  die "Unable to create the review artifact directory: $artifact_dir" 3
fi
# canonicalize only after the directory exists (canonical_dir resolves
# through pwd -P); the containment check below depends on this form
artifact_dir="$(canonical_dir "$artifact_dir")"
artifact_timestamp="$(date -u +%Y%m%d-%H%M%S)"
artifact="$artifact_dir/kimi-${slug}-${artifact_timestamp}-$$.md"
# defense in depth on top of the slug allowlist: the resolved artifact parent
# must stay inside the configured artifact directory
case "$(canonical_dir "$(dirname "$artifact")")" in
  "$artifact_dir"|"$artifact_dir"/*) : ;;
  *) die "Resolved artifact path escapes --artifact-dir: $artifact" 2 ;;
esac
# the artifact name embeds pid + second-granularity timestamp, so a hostile
# artifact directory can pre-plant a symlink at a guessed name; refuse to
# follow one, and let the sidecar mkdir fail on a symlinked leaf too
if [[ -L "$artifact" || -e "$artifact" ]]; then
  die "Refusing to follow a pre-existing artifact path: $artifact" 3
fi
sidecar_dir="${artifact%.md}.d"
if [[ -L "$sidecar_dir" ]]; then
  die "Refusing to follow a pre-existing sidecar path: $sidecar_dir" 3
fi
if ! mkdir -p "$sidecar_dir"; then
  die "Unable to create the review sidecar directory: $sidecar_dir" 3
fi
review_processes="$sidecar_dir/process-tree.log"
: >"$review_processes" || die "Unable to initialize the process evidence log." 3
sandbox_profile="$sidecar_dir/sandbox.sb"

# ---------- media detection + capability preflight ----------

detected_media_paths="$(git -c core.quotepath=false -c diff.relative=false diff --name-only --diff-filter=ACMR ${diff_args[@]+"${diff_args[@]}"} | awk -v root="$repo_root" 'tolower($0) ~ /\.(png|jpe?g|gif|webp|svg|mp4|mov|webm|m4v|avi|mkv|mts|m2ts|3gp)$/ { print root "/" $0 }')"
explicit_media_paths="$(printf '%s\n' "$media_paths" | awk -v cwd="$PWD" 'NF { if ($0 ~ /^\//) print; else print cwd "/" $0 }')"
media_paths="$(printf '%s\n%s\n' "$explicit_media_paths" "$detected_media_paths" | awk 'NF && !seen[$0]++')"
media_scope="${media_paths:-none}"
visual_preflight="not-required"
provider_identity="unknown (catalog not queried)"
image_media_paths="$(printf '%s\n' "$media_paths" | awk 'tolower($0) ~ /\.(png|jpe?g|gif|webp|svg)$/')"
video_media_paths="$(printf '%s\n' "$media_paths" | awk 'tolower($0) ~ /\.(mp4|mov|webm|m4v|avi|mkv|mts|m2ts|3gp)$/')"
provider_json=""
if provider_json="$(read_provider_catalog 2>/dev/null)"; then
  provider_identity="$(printf '%s' "$provider_json" | jq -r --arg model "$model" '.models[$model].provider // "unknown (model has no provider field)"' 2>/dev/null)"
  provider_identity="${provider_identity:-unknown (catalog parse failed)}"
fi
if [[ -n "$media_paths" ]]; then
  visual_preflight="catalog-passed"
  if [[ -z "$provider_json" ]]; then
    visual_preflight="Unable to verify media capabilities for $model; visual evidence was skipped"
    media_scope="none"
  else
    if [[ -n "$image_media_paths" ]] &&
      ! printf '%s' "$provider_json" |
        jq -e --arg model "$model" '(.models[$model].capabilities // null) as $caps | if ($caps | type) == "array" then ($caps | index("image_in")) != null else false end' >/dev/null
    then
      visual_preflight="Resolved model does not advertise image_in; image evidence was skipped"
      media_scope="$(printf '%s\n' "$media_scope" | awk 'tolower($0) !~ /\.(png|jpe?g|gif|webp|svg)$/')"
    fi
    if [[ -n "$video_media_paths" ]] &&
      ! printf '%s' "$provider_json" |
        jq -e --arg model "$model" '(.models[$model].capabilities // null) as $caps | if ($caps | type) == "array" then ($caps | index("video_in")) != null else false end' >/dev/null
    then
      if [[ "$visual_preflight" == "catalog-passed" ]]; then
        visual_preflight="Resolved model does not advertise video_in; video evidence was skipped"
      else
        visual_preflight="$visual_preflight; video capability was unavailable, so video evidence was skipped"
      fi
      media_scope="$(printf '%s\n' "$media_scope" | awk 'tolower($0) !~ /\.(mp4|mov|webm|m4v|avi|mkv|mts|m2ts|3gp)$/')"
    fi
  fi
  media_scope="${media_scope:-none}"
fi

# ---------- sandbox ----------

isolation="prompt-only"
runner=()

if [[ "$(uname -s)" == "Darwin" ]] && sandbox_exec_path="$(command -v sandbox-exec 2>/dev/null)"; then
  kimi_cache="$(canonical_dir "$HOME/Library/Caches/kimi-code")"
  # the resolved kimi binary itself must stay readable; it usually lives
  # under KIMI_HOME, but a shim or test double may not
  kimi_bin="$(command -v kimi 2>/dev/null || true)"
  if [[ -n "$kimi_bin" ]]; then
    kimi_bin="$(perl -MCwd=abs_path -e 'print abs_path($ARGV[0]) // $ARGV[0]' "$kimi_bin" 2>/dev/null || printf '%s\n' "$kimi_bin")"
  fi
  # Kimi is commonly a Node SEA binary or a /usr/bin/env node launcher. Keep
  # the actual launcher/runtime paths readable so strict mode does not turn a
  # valid installation into exit 126 (for example ServBay's node wrapper).
  node_bin="$(command -v node 2>/dev/null || true)"
  if [[ -n "$node_bin" ]]; then
    node_bin="$(perl -MCwd=abs_path -e 'print abs_path($ARGV[0]) // $ARGV[0]' "$node_bin" 2>/dev/null || printf '%s\n' "$node_bin")"
  fi
  node_runtime_dir="$(dirname "${node_bin:-/}")"
  node_launcher_dir="$(dirname "$(command -v node 2>/dev/null || printf '%s' /bin/node)")"
  servbay_runtime_dir=""
  case "$kimi_bin $node_bin $node_launcher_dir" in
    *"/Applications/ServBay/"*) servbay_runtime_dir="/Applications/ServBay" ;;
  esac
  if [[ "$strict_scope" == "1" ]]; then
    # Strict gate profile: deny-by-default file reads. Readable content is
    # limited to system paths, the Kimi runtime (binary/config/cache), this
    # run's dedicated temporary directory, and — appended by the strict-scope
    # section below — the changed files and explicitly approved paths. File
    # metadata (names/existence) is allowed globally; content is not. The
    # credential deny list stays as defense in depth and is validated against
    # before any strict allow rule is appended.
    # The profile doubles as durable evidence at <artifact>.d/sandbox.sb
    if ! cat >"$sandbox_profile" <<'SANDBOX_PROFILE'
(version 1)
(deny default)
(allow process*)
(allow network*)
(allow sysctl-read)
(allow mach-lookup)
(allow ipc-posix-shm-read-data)
(allow file-read-metadata)
(allow file-read* (literal "/"))
(allow file-read* (subpath "/System"))
(allow file-read* (subpath "/usr"))
(allow file-read* (subpath "/bin"))
(allow file-read* (subpath "/sbin"))
(allow file-read* (subpath "/Library"))
(allow file-read* (subpath "/private/etc"))
(allow file-read* (subpath "/etc"))
(allow file-read* (subpath "/private/var/db"))
(allow file-read* (subpath "/var/db"))
(allow file-read* (subpath "/opt/homebrew"))
(allow file-read* (subpath "/dev"))
(allow file-read* (subpath (param "KIMI_HOME")))
(allow file-read* (subpath (param "KIMI_CACHE")))
(allow file-read* (literal (param "KIMI_BIN")))
(allow file-read* (subpath (param "NODE_RUNTIME_DIR")))
(allow file-read* (subpath (param "NODE_LAUNCHER_DIR")))
(allow file-read* (subpath (param "SERVBAY_RUNTIME_DIR")))
(allow file-read* (subpath (param "RUN_TMP")))
(allow file-write* (subpath (param "KIMI_HOME")))
(allow file-write* (subpath (param "KIMI_CACHE")))
(allow file-write* (subpath (param "RUN_TMP")))
(allow file-write* (literal "/dev/null"))
(deny file-read* (subpath (param "SSH_DIR")))
(deny file-read* (subpath (param "AWS_DIR")))
(deny file-read* (subpath (param "GNUPG_DIR")))
(deny file-read* (subpath (param "GH_CONFIG_DIR")))
(deny file-read* (subpath (param "CODEX_DIR")))
(deny file-read* (subpath (param "KUBE_DIR")))
(deny file-read* (subpath (param "DOCKER_DIR")))
(deny file-read* (subpath (param "AZURE_DIR")))
(deny file-read* (subpath (param "GCLOUD_DIR")))
(deny file-read* (subpath (param "GIT_CREDENTIALS_FILE")))
(deny file-read* (subpath (param "NETRC_FILE")))
(deny file-read* (subpath (param "PIP_CONFIG_DIR")))
(deny file-read* (subpath (param "BUNDLE_DIR")))
(deny file-read* (subpath (param "TERRAFORM_DIR")))
(deny file-read* (subpath (param "CLAUDE_DIR")))
(deny file-read* (literal (param "GIT_CREDENTIALS_FILE")))
(deny file-read* (literal (param "NETRC_FILE")))
(deny file-read* (literal (param "NPMRC_FILE")))
(deny file-read* (literal (param "PYPRC_FILE")))
(deny file-read* (literal (param "YARNRC_FILE")))
(deny file-read* (literal (param "GIT_XDG_CREDENTIALS")))
(deny file-read* (literal (param "PIP_LEGACY_FILE")))
(deny file-read* (literal (param "BUNDLE_CONFIG_FILE")))
(deny file-read* (literal (param "GEM_CREDENTIALS_FILE")))
(deny file-read* (literal (param "M2_SETTINGS_FILE")))
(deny file-read* (literal (param "GRADLE_PROPERTIES_FILE")))
(deny file-read* (literal (param "CARGO_CREDENTIALS_FILE")))
(deny file-read* (literal (param "COMPOSER_AUTH_FILE")))
(deny file-read* (literal (param "TERRAFORM_CREDENTIALS_FILE")))
(deny file-read* (subpath (param "WORKSPACE")))
(deny file-read* (subpath (param "GIT_DIR")))
(deny file-write* (subpath (param "WORKSPACE")))
(deny file-write* (subpath (param "GIT_DIR")))
(deny file-write* (subpath (param "SKILL_DIR")))
SANDBOX_PROFILE
    then
      die 'Unable to write the macOS sandbox profile.' 3
    fi
    isolation="macOS sandbox (strict-scope): deny-by-default file reads; only the snapshot, changed files, approved paths, the Kimi runtime, and system paths are readable"
  else
    # the profile doubles as durable evidence at <artifact>.d/sandbox.sb
    if ! cat >"$sandbox_profile" <<'SANDBOX_PROFILE'
(version 1)
(deny default)
(allow process*)
(allow file-read*)
(deny file-read* (subpath (param "SSH_DIR")))
(deny file-read* (subpath (param "AWS_DIR")))
(deny file-read* (subpath (param "GNUPG_DIR")))
(deny file-read* (subpath (param "GH_CONFIG_DIR")))
(deny file-read* (subpath (param "CODEX_DIR")))
(deny file-read* (subpath (param "KUBE_DIR")))
(deny file-read* (subpath (param "DOCKER_DIR")))
(deny file-read* (subpath (param "AZURE_DIR")))
(deny file-read* (subpath (param "GCLOUD_DIR")))
(deny file-read* (subpath (param "GIT_CREDENTIALS_FILE")))
(deny file-read* (subpath (param "NETRC_FILE")))
(deny file-read* (subpath (param "PIP_CONFIG_DIR")))
(deny file-read* (subpath (param "BUNDLE_DIR")))
(deny file-read* (subpath (param "TERRAFORM_DIR")))
(deny file-read* (subpath (param "CLAUDE_DIR")))
(deny file-read* (literal (param "GIT_CREDENTIALS_FILE")))
(deny file-read* (literal (param "NETRC_FILE")))
(deny file-read* (literal (param "NPMRC_FILE")))
(deny file-read* (literal (param "PYPRC_FILE")))
(deny file-read* (literal (param "YARNRC_FILE")))
(deny file-read* (literal (param "GIT_XDG_CREDENTIALS")))
(deny file-read* (literal (param "PIP_LEGACY_FILE")))
(deny file-read* (literal (param "BUNDLE_CONFIG_FILE")))
(deny file-read* (literal (param "GEM_CREDENTIALS_FILE")))
(deny file-read* (literal (param "M2_SETTINGS_FILE")))
(deny file-read* (literal (param "GRADLE_PROPERTIES_FILE")))
(deny file-read* (literal (param "CARGO_CREDENTIALS_FILE")))
(deny file-read* (literal (param "COMPOSER_AUTH_FILE")))
(deny file-read* (literal (param "TERRAFORM_CREDENTIALS_FILE")))
(allow file-read* (subpath (param "SKILL_DIR")))
(allow file-write* (subpath (param "KIMI_HOME")))
(allow file-write* (subpath (param "TMP_DIR")))
(allow file-write* (literal "/dev/null"))
(allow network*)
(allow sysctl-read)
(deny file-write* (subpath (param "WORKSPACE")))
(deny file-write* (subpath (param "GIT_DIR")))
(deny file-write* (subpath (param "SKILL_DIR")))
SANDBOX_PROFILE
    then
      die 'Unable to write the macOS sandbox profile.' 3
    fi
    isolation="macOS sandbox: repository, git, and skill writes denied; common credential reads denied${canon_note}"
  fi
  if [[ -n "$codex_default_dir" ]]; then
    # additive deny for the literal $HOME/.codex boundary even when CODEX_HOME
    # points elsewhere; appended after the broad read allow on non-strict
    # profiles so the deny outranks it (SBPL resolves top-to-bottom, last
    # match wins — the placement is load-bearing, keep deny rules after
    # allows if the profile is ever reordered)
    printf '(deny file-read* (subpath (param "CODEX_DEFAULT_DIR")))\n' >>"$sandbox_profile"
  fi
  runner=("$sandbox_exec_path" -D "KIMI_HOME=$kimi_home" -D "KIMI_CACHE=$kimi_cache" -D "KIMI_BIN=$kimi_bin" -D "NODE_RUNTIME_DIR=${node_runtime_dir:-/bin}" -D "NODE_LAUNCHER_DIR=${node_launcher_dir:-/bin}" -D "SERVBAY_RUNTIME_DIR=${servbay_runtime_dir:-/bin}" -D "TMP_DIR=$tmp_dir" -D "RUN_TMP=$run_tmp" -D "WORKSPACE=$repo_root" -D "GIT_DIR=$git_dir" -D "SKILL_DIR=$skill_dir" -D "CODEX_DIR=$codex_dir" -D "SSH_DIR=$(rp_path "$HOME/.ssh")" -D "AWS_DIR=$(rp_path "$HOME/.aws")" -D "GNUPG_DIR=$(rp_path "$HOME/.gnupg")" -D "GH_CONFIG_DIR=$(rp_path "$HOME/.config/gh")" -D "KUBE_DIR=$(rp_path "$HOME/.kube")" -D "DOCKER_DIR=$(rp_path "$HOME/.docker")" -D "AZURE_DIR=$(rp_path "$HOME/.azure")" -D "GCLOUD_DIR=$(rp_path "$HOME/.config/gcloud")" -D "GIT_CREDENTIALS_FILE=$(rp_path "$HOME/.git-credentials")" -D "NETRC_FILE=$(rp_path "$HOME/.netrc")" -D "PIP_CONFIG_DIR=$(rp_path "$HOME/.config/pip")" -D "BUNDLE_DIR=$(rp_path "$HOME/.bundle")" -D "TERRAFORM_DIR=$(rp_path "$HOME/.terraform.d")" -D "CLAUDE_DIR=$(rp_path "$HOME/.claude")" -D "NPMRC_FILE=$(rp_path "$HOME/.npmrc")" -D "PYPRC_FILE=$(rp_path "$HOME/.pypirc")" -D "YARNRC_FILE=$(rp_path "$HOME/.yarnrc.yml")" -D "GIT_XDG_CREDENTIALS=$(rp_path "$HOME/.config/git/credentials")" -D "PIP_LEGACY_FILE=$(rp_path "$HOME/.pip/pip.conf")" -D "BUNDLE_CONFIG_FILE=$(rp_path "$HOME/.bundle/config")" -D "GEM_CREDENTIALS_FILE=$(rp_path "$HOME/.gem/credentials")" -D "M2_SETTINGS_FILE=$(rp_path "$HOME/.m2/settings.xml")" -D "GRADLE_PROPERTIES_FILE=$(rp_path "$HOME/.gradle/gradle.properties")" -D "CARGO_CREDENTIALS_FILE=$(rp_path "$HOME/.cargo/credentials.toml")" -D "COMPOSER_AUTH_FILE=$(rp_path "$HOME/.composer/auth.json")" -D "TERRAFORM_CREDENTIALS_FILE=$(rp_path "$HOME/.terraform.d/credentials.tfrc.json")" -f "$sandbox_profile")
  [[ -n "$codex_default_dir" ]] && runner+=(-D "CODEX_DEFAULT_DIR=$codex_default_dir")
fi

# ---------- strict scope ----------

scope_mode="open"
strict_prompt_block=""
if [[ "$strict_scope" == "1" ]]; then
  if (( ${#runner[@]} > 0 )); then
    scope_mode="strict"
    changed_list="$(git -c core.quotepath=false -c diff.relative=false diff --name-only ${diff_args[@]+"${diff_args[@]}"} | awk 'NF')"
    changed_count="$(printf '%s\n' "$changed_list" | awk 'NF' | wc -l | tr -d ' ')"
    if [[ "$changed_count" -gt 100 ]]; then
      die "--strict-scope supports at most 100 changed files; split the scope." 2
    fi
    # explicit pathspecs must match the actual diff; otherwise the allowlist
    # and the prompt describe different readable sets. options, revision
    # ranges (a..b / a...b), and resolvable revisions are not pathspecs;
    # everything after a `--` separator always is. Matching is delegated to
    # Git itself (git diff --name-only <rev-args> -- <pathspec>) so magic
    # pathspecs such as :(icase) or :(glob) behave exactly as Git resolves
    # them instead of relying on a local string reimplementation.
    after_ddash=0
    rev_args=()
    pathspec_args=()
    for diff_arg in ${diff_args[@]+"${diff_args[@]}"}; do
      if [[ "$diff_arg" == "--" ]]; then
        after_ddash=1
        continue
      fi
      if [[ "$after_ddash" != "1" ]]; then
        if [[ "$diff_arg" == -* ]] || [[ "$diff_arg" == *..* ]] ||
          git rev-parse --verify --quiet "$diff_arg" >/dev/null 2>&1; then
          rev_args+=("$diff_arg")
          continue
        fi
      fi
      pathspec_args+=("$diff_arg")
    done
    for ps in ${pathspec_args[@]+"${pathspec_args[@]}"}; do
      if [[ -z "$(git -c core.quotepath=false -c diff.relative=false diff --name-only ${rev_args[@]+"${rev_args[@]}"} -- "$ps" 2>/dev/null)" ]]; then
        die "strict-scope: pathspec '$ps' has no changes in the selected diff; pass non-diff evidence via KIMI_REVIEW_STRICT_ALLOW_PATHS instead." 2
      fi
    done
    # readable-content set, mirrored into the violation classifier at
    # finalization: a denied-read signal is only counted when it carries
    # provenance that the target lies outside this set
    strict_allowed_paths=("$run_tmp" "$kimi_home" "$kimi_cache" "$kimi_bin" "/System" "/usr" "/bin" "/sbin" "/Library" "/private/etc" "/etc" "/private/var/db" "/var/db" "/opt/homebrew" "/dev")
    strict_denied_paths=()
    # run Kimi outside the repository: no usable .git directory is exposed at
    # all, so the boundary no longer depends on sandbox literal/param
    # semantics or on which path form a caller happens to type. The strict
    # profile is deny-by-default and already denies WORKSPACE/GIT_DIR reads
    # as defense in depth; only the allows appended here reopen content, and
    # every appended path is validated against the credential boundaries.
    i=0
    if [[ "$projection" == "1" ]]; then
      # sanitized projection: the review sees scrubbed copies only, never the
      # original snapshot or the original changed files
      projection_dir="$(mktemp -d "$run_tmp/kimi-review-projection.XXXXXX")" || die 'Unable to create the review projection directory.' 3
      mkdir -p "$projection_dir/files" || die 'Unable to create the review projection directory.' 3
      projection_source_dir="$run_tmp/kimi-review-projection-source"
      mkdir -p "$projection_source_dir" || die 'Unable to create the projection source staging directory.' 3
      projection_manifest="$projection_dir/manifest.jsonl"
      : >"$projection_manifest" || die 'Unable to create the review projection manifest.' 3
      scrub_projection_file "$diff_snapshot" "$projection_dir/diff.patch" "<diff-snapshot>" || die 'Unable to build the sanitized diff projection.' 3
      strict_denied_paths+=("$diff_snapshot" "$projection_source_dir")
      while IFS= read -r cf; do
        [[ -n "$cf" ]] || continue
        if path_overlaps_boundary "$(rp_path "$repo_root/$cf")"; then
          die "strict-scope: changed file '$cf' is under a credential boundary; refusing to project it." 2
        fi
        cf_abs="$projection_source_dir/$cf"
        materialize_selected_file "$cf" "$cf_abs" || continue
        scrub_projection_file "$cf_abs" "$projection_dir/files/$cf" "$cf" || die "Unable to project changed file: $cf" 3
        i=$((i + 1))
      done <<<"$changed_list"
      strict_changed=$i
      # the raw snapshot shares the per-run directory with the projection;
      # close it explicitly so only the scrubbed copy is readable
      printf '(deny file-read* (literal (param "RAW_SNAPSHOT")))\n' >>"$sandbox_profile" || die 'Unable to extend the strict-scope sandbox profile.' 3
      printf '(deny file-read* (subpath (param "PROJECTION_SOURCE")))\n' >>"$sandbox_profile" || die 'Unable to extend the strict-scope sandbox profile.' 3
      runner+=(-D "RAW_SNAPSHOT=$diff_snapshot")
      runner+=(-D "PROJECTION_SOURCE=$projection_source_dir")
      strict_cwd="$projection_dir"
      prompt_snapshot="$projection_dir/diff.patch"
      review_target="sanitized-projection"
      # bind the projection to its sources: hashes and replacement counts
      jq -n --arg root "$repo_root" \
        --arg statement "Sanitized projection: secret-pattern literals in the reviewed snapshot and changed files were replaced with [[REDACTED:<rule>]] placeholders. source_sha256 binds each entry to the original content; projection_sha256 binds it to the reviewed copy. The review artifact describes the projection, not the original files." \
        --slurpfile entries "$projection_manifest" \
        '{mode:"sanitized-projection",source_root:$root,statement:$statement,entries:$entries}' \
        >"$sidecar_dir/projection.json" || die 'Unable to write the projection manifest sidecar.' 3
      # visual evidence: point media paths at their projected copies when present
      if [[ "$media_scope" != "none" ]]; then
        media_scope="$(printf '%s\n' "$media_scope" | while IFS= read -r mp; do
          case "$mp" in
            "$repo_root"/*)
              mp_rel="${mp#"$repo_root"/}"
              [[ -f "$projection_dir/files/$mp_rel" ]] && mp="$projection_dir/files/$mp_rel"
              ;;
          esac
          printf '%s\n' "$mp"
        done)"
      fi
    else
      strict_cwd="$(mktemp -d "$run_tmp/kimi-review-cwd.XXXXXX")" || die 'Unable to create the strict working directory.' 3
      while IFS= read -r cf; do
        [[ -n "$cf" ]] || continue
        cf_abs="$repo_root/$cf"
        if path_overlaps_boundary "$(rp_path "$cf_abs")"; then
          die "strict-scope: changed file '$cf' is under a credential boundary; refusing to allow it." 2
        fi
        materialized_path="$strict_cwd/$cf"
        materialize_selected_file "$cf" "$materialized_path" || continue
        printf '(allow file-read* (literal (param "STRICT_FILE_%s")))\n' "$i" >>"$sandbox_profile" || die 'Unable to extend the strict-scope sandbox profile.' 3
        runner+=(-D "STRICT_FILE_$i=$materialized_path")
        strict_allowed_paths+=("$materialized_path")
        # For an ordinary worktree diff, retain the selected current file path
        # as a compatibility allow for tools that resolve absolute paths. A
        # range or staged review never reopens the repository copy.
        if [[ -z "$diff_new_tree" && "$diff_cached" != "1" ]]; then
          printf '(allow file-read* (literal (param "STRICT_ORIGINAL_%s")))\n' "$i" >>"$sandbox_profile" || die 'Unable to extend the strict-scope sandbox profile.' 3
          runner+=(-D "STRICT_ORIGINAL_$i=$cf_abs")
          strict_allowed_paths+=("$cf_abs")
        fi
        i=$((i + 1))
      done <<<"$changed_list"
      strict_changed=$i
    fi
    j=0
    while IFS= read -r ap; do
      [[ -n "$ap" ]] || continue
      [[ "$ap" == /* ]] || ap="$PWD/$ap"
      ap="$(canonical_dir "$ap")"
      case "$ap" in
        /|/Users|"$HOME")
          die "strict-scope: approved path '$ap' is too broad; approve a narrower directory." 2 ;;
      esac
      if path_overlaps_boundary "$(rp_path "$ap")"; then
        die "strict-scope: approved path '$ap' overlaps a credential boundary; refusing to allow it." 2
      fi
      if [[ -d "$ap" ]]; then
        allow_kind="subpath"
      else
        allow_kind="literal"
      fi
      printf '(allow file-read* (%s (param "STRICT_ALLOW_%s")))\n' "$allow_kind" "$j" >>"$sandbox_profile" || die 'Unable to extend the strict-scope sandbox profile.' 3
      runner+=(-D "STRICT_ALLOW_$j=$ap")
      strict_allowed_paths+=("$ap")
      j=$((j + 1))
    done <<<"${KIMI_REVIEW_STRICT_ALLOW_PATHS:-}"
    strict_approved=$j
    # explicit media paths are user-authorized visual evidence; validate them
    # like approved paths and allowlist them so strict reviews can actually
    # read untracked or out-of-repo media. anything already covered (changed
    # files, approved paths, the per-run directory — which also holds the
    # projection copies) is skipped. media_scope is authoritative: it is
    # capability-filtered and, in projection mode, already remapped to the
    # projected copies, so the originals are never reopened.
    m=0
    while IFS= read -r mp; do
      [[ -n "$mp" && "$mp" != "none" ]] || continue
      mp_canon="$mp"
      if [[ -e "$mp" ]]; then
        mp_canon="$(canonical_dir "$(dirname "$mp")")/$(basename "$mp")"
      fi
      mp_covered=0
      for covered_path in ${strict_allowed_paths[@]+"${strict_allowed_paths[@]}"}; do
        case "$mp_canon" in
          "$covered_path"|"$covered_path"/*) mp_covered=1; break ;;
        esac
      done
      (( mp_covered == 1 )) && continue
      if path_overlaps_boundary "$mp_canon"; then
        die "strict-scope: media path '$mp' overlaps a credential boundary; refusing to allow it." 2
      fi
      printf '(allow file-read* (literal (param "STRICT_MEDIA_%s")))\n' "$m" >>"$sandbox_profile" || die 'Unable to extend the strict-scope sandbox profile.' 3
      runner+=(-D "STRICT_MEDIA_$m=$mp_canon")
      strict_allowed_paths+=("$mp_canon")
      m=$((m + 1))
    done <<<"$media_scope"
    strict_media=$m
    isolation="$isolation; review runs outside the repository; $strict_changed changed file(s), $strict_approved approved path(s), and $strict_media media path(s) readable"
    if [[ "$projection" == "1" ]]; then
      isolation="$isolation; review target is a sanitized projection (secret-shaped literals replaced by placeholders)"
      strict_prompt_block="STRICT SCOPE + SANITIZED PROJECTION: you are running outside the repository, reviewing a sanitized projection. The current directory contains diff.patch (the exact reviewed diff) and files/ (the changed files in repository-relative layout). Secret-shaped literals were replaced by the runner with [[REDACTED:<rule>]] placeholders that mark synthetic fixture values; do not report their presence as a finding and do not try to recover the original values. Read only diff.patch, files/, and explicitly approved paths (absolute paths). Do not cd into, query, or run git commands against the original repository. Do not search recursively, do not consult review history. Out-of-scope reads are denied by the sandbox; when a read is denied, record it under caveats as a scope boundary and continue with in-scope evidence only."
    else
      strict_prompt_block="STRICT SCOPE: you are running outside the repository. Review the exact diff from the fallback snapshot and read only the files changed in that diff and explicitly approved paths (absolute paths). Do not cd into, query, or run git commands against the repository — the object database (git show/log/diff against any ref) is out of scope. Do not search recursively, do not consult review history. Out-of-scope reads are denied by the sandbox; when a read is denied, record it under caveats as a scope boundary and continue with in-scope evidence only."
    fi
  else
    scope_mode="strict-unenforced"
    if [[ "$projection" == "1" ]]; then
      die '--projection requires --strict-scope with an enforceable sandbox; sandbox-exec is unavailable on this host.' 2
    fi
    isolation="$isolation; strict-scope requested but sandbox-exec is unavailable - scope read boundary NOT enforced"
    strict_prompt_block="STRICT SCOPE requested but the sandbox is unavailable: read only the fallback snapshot and the files changed in the reviewed diff; do not search the repository recursively, consult review history, or read files outside the reviewed diff."
  fi
fi

# ---------- prompt ----------

if ! cat >"$prompt" <<EOF
Act as a strict senior code reviewer. Review $scope in the current repository.

Read the diff and relevant source, tests, configuration, migrations, and call sites yourself. Keep this review strictly read-only: do not edit, create, delete, rename, commit, push, install packages, or change configuration. Do not ask clarifying questions; state caveats and continue when information is missing.
$strict_prompt_block
For each path under Visual evidence, use ReadMediaFile and correlate what is visibly rendered with the relevant source. Do not infer image contents from filenames. If no paths are listed, skip visual review. If any image cannot be read, name it under caveats and do not claim it was inspected. Detected paths are absolute; pass explicit paths as absolute paths when they are outside the repository. The list may contain paths detected from the selected diff as well as explicit user-authorized paths.

Check correctness, regression risk, security and authorization, tenant isolation, data integrity, transaction and concurrency behavior, state transitions, idempotency, API compatibility, failure paths, boundary conditions, and project conventions. Prioritize actionable defects over style preferences. Do not report a concern unless the repository evidence supports it.

Return:
1. Verdict: PASS, NEEDS_ATTENTION, or BLOCKED.
2. Findings ordered by severity. For each finding include severity (P0/P1/P2/P3), file and line when known, trigger or data flow, concrete impact, and a minimal remediation direction.
3. Caveats and files or checks that could not be inspected.
4. A short list of verification commands or tests that should run next.

End the final message with a fenced \`\`\`json block of the exact form {"verdict":"PASS|NEEDS_ATTENTION|BLOCKED","findings":[{"severity":"P0|P1|P2|P3","summary":"one line"}],"caveats":"..."} (findings may be an empty array). It restates the verdict above in machine-readable form and must stay consistent with the written sections.

Review scope: $scope
Exact diff fallback snapshot: $prompt_snapshot
Visual evidence paths (one per line; none means no visual evidence):
$media_scope
Visual capability preflight: $visual_preflight

If the repository tools cannot retrieve the requested scope reliably, read the exact diff from the fallback snapshot. Treat it as read-only evidence and do not modify or delete it.
EOF
then
  die 'Unable to create the review prompt.' 3
fi

# ---------- interrupt-safe artifact ----------

evidence_class="runtime diagnostic only (.omx/artifacts-style path); NOT stage-gate evidence - rerun with --durable-dir for gate use"
if [[ -n "$durable_dir" ]]; then
  evidence_class="durable gate evidence (repo-governed path: $durable_dir)"
fi

if ! {
  printf '# Kimi Review: %s\n\n' "$slug"
  printf -- '- Status: RUNNING\n- Evidence class: %s\n- Review target: %s\n- Runner: ask-kimi-review/scripts/run_review.sh v%s\n\n' "$evidence_class" "$review_target" "$RUNNER_VERSION"
  printf '## Original Task\n\nReview scope: `%s`\n\n' "$scope"
  printf '## Prompt\n\n```text\n'; cat "$prompt"; printf '\n```\n\n'
} >"$artifact"; then
  die "Unable to pre-create the review artifact: $artifact" 3
fi
artifact_created=1
cp "$prompt" "$sidecar_dir/prompt.txt" 2>/dev/null || true
{
  printf 'kimi -m %s --output-format stream-json --skills-dir <empty run dir> -p <prompt from %s>\n' "$model" "$sidecar_dir/prompt.txt"
  printf '# scope: %s | diff args: %s | timeout: %ss | strict-scope: %s\n' "$scope" "${diff_args[*]:-}" "$timeout_seconds" "$strict_scope"
} >"$sidecar_dir/command.txt" 2>/dev/null || true
write_execution_json "RUNNING" || printf 'Unable to write execution.json sidecar for %s\n' "$artifact" >&2

update_status() {
  local tmp
  tmp="$(mktemp -t kimi-review-status.XXXXXX)" || return 1
  sed "s/^- Status: .*/- Status: $1/" "$artifact" >"$tmp" && cat "$tmp" >"$artifact"
  unlink "$tmp" 2>/dev/null || true
}

# Replaces a header line by prefix without sed delimiter/escaping issues.
update_line() {
  local prefix="$1" replacement="$2" tmp
  tmp="$(mktemp -t kimi-review-line.XXXXXX)" || return 1
  awk -v pat="$prefix" -v repl="$replacement" 'index($0, pat) == 1 { print repl; next } { print }' "$artifact" >"$tmp" && cat "$tmp" >"$artifact"
  unlink "$tmp" 2>/dev/null || true
}

# Shared evidence finalization. Callers set: final_status, final_exit_code,
# final_timed_out, final_signal, final_note, finished_at, duration_ms_disp,
# process_release, resource_warning, mutation_check, mutation_warning.
append_evidence_and_cleanup() {
  local quarantine_note="" empty_warning="" extraction_status="" final_text=""
  local verdict="" tool_summary="" session_id="" secret_hits="" temporary_release=""
  local hits_out="" hits_err="" rc_out=0 rc_err=0 secret_sources=""
  local timeout_command_desc="native bash watchdog (sleep ${timeout_seconds}s + TERM/KILL; no timeout utility found)"

  update_status "$final_status" || true

  if [[ -n "$gtimeout_bin" ]]; then
    timeout_command_desc="$gtimeout_bin -k 5s ${timeout_seconds}s"
  elif [[ -n "$timeout_bin" ]]; then
    timeout_command_desc="$timeout_bin -k 5s ${timeout_seconds}s"
  fi

  if [[ ! -s "$raw_out" ]]; then
    empty_output=1
    empty_warning=$'> [!WARNING]\n> Kimi stdout was empty. Report the exit code and provider diagnostics; do not invent findings.\n\n'
  fi

  hits_out="$(scan_secrets "$raw_out")"; rc_out=$?
  hits_err="$(scan_secrets "$raw_err")"; rc_err=$?
  secret_hits="$(printf '%s\n%s\n' "$hits_out" "$hits_err" | awk 'NF' | sort -u)"
  secret_scan_failed=false
  (( rc_out >= 2 || rc_err >= 2 )) && secret_scan_failed=true
  secret_sources=""
  [[ -n "$hits_out" ]] && secret_sources="stdout"
  [[ -n "$hits_err" ]] && secret_sources="${secret_sources}${secret_sources:+ }stderr"
  if [[ "$secret_scan_failed" == true ]]; then
    # fail closed: a scan that could not complete is treated as a detection
    secret_detected_bool=true
    quarantine_note="secret scan could not complete safely"
    [[ -n "$secret_hits" ]] && quarantine_note="$quarantine_note; partial rule hits: $(printf '%s\n' "$secret_hits" | awk '{printf "%s%s", (NR>1?", ":""), $0}')"
  elif [[ -n "$secret_hits" ]]; then
    secret_detected_bool=true
    quarantine_note="$(printf '%s\n' "$secret_hits" | awk '{printf "%s%s", (NR>1?", ":""), $0}')"
  fi

  if [[ "$scope_mode" == "strict" ]]; then
    # unique denied events (per tool call) are authoritative; raw log hits are
    # reported alongside because one denial can appear in both streams.
    # A phrase-bearing tool result only counts when it carries provenance of
    # an actual out-of-scope attempt:
    #   a) "not a git repository" paired with a git command in the tool call
    #      arguments (git use is prohibited in strict mode), or
    #   b) an absolute path (in the arguments or the error text) outside the
    #      readable set recorded in strict_allowed_paths, or
    #   c) a "../" traversal segment in the denied target, or
    #   d) a line-anchored shell error shape ("cmd: target: Operation not
    #      permitted") returned by a Bash tool call (relative-target denials
    #      leave no absolute path for rule b).
    # Allowed file content merely quoting these phrases stays benign (a Read
    # result is file content, not a shell denial). If the classifier itself
    # fails, fall back to the conservative phrase count.
    strict_allowed_json="$(printf '%s\n' ${strict_allowed_paths[@]+"${strict_allowed_paths[@]}"} | jq -Rn '[inputs | select(length > 0)]' 2>/dev/null)"
    strict_allowed_json="${strict_allowed_json:-[]}"
    strict_denied_json="$(printf '%s\n' ${strict_denied_paths[@]+"${strict_denied_paths[@]}"} | jq -Rn '[inputs | select(length > 0)]' 2>/dev/null)"
    strict_denied_json="${strict_denied_json:-[]}"
    violation_events="$(jq -Rrn --argjson allowed "$strict_allowed_json" --argjson denied "$strict_denied_json" '
      def under($p; $base): ($p == $base) or ($p | startswith($base + "/"));
      def abs_paths: [scan("/[A-Za-z0-9._~+@%=-][A-Za-z0-9._~+@%=/+-]*") | sub("[\\.:,;\")]+$"; "")];
      [inputs | fromjson? // empty | select(type == "object")] as $ev
      | ($ev | map(select(.role == "assistant" and .tool_calls) | .tool_calls[] | {id: (.id // ""), args: (.function.arguments // ""), name: (.function.name // "")})) as $calls
      | [ $ev[]
          | select(.role == "tool" and (.content? | type) == "string" and (.content | test("operation not permitted|not a git repository"; "i")))
          | . as $t
          | (($calls | map(select(.id == ($t.tool_call_id // ""))) | first // {args: "", name: ""})) as $call
          | select(
              (($t.content | test("not a git repository"; "i")) and ($call.args | test("(^|[^A-Za-z])git( |$)")))
              or (($t.content | test("\\.\\./")) and ($t.content | test("operation not permitted"; "i")))
              or (($call.name == "Bash") and ($t.content | test("(^|\n)[^:\n]{1,40}: [^:\n]+: Operation not permitted")))
              or ([ (($t.content + " " + $call.args) | abs_paths)[] | . as $p
                      | select(([$denied[] | . as $d | select(under($p; $d))] | length > 0)
                              or ([$allowed[] | . as $a | select(under($p; $a))] | length == 0))] | length > 0)
            )
          | ($t.tool_call_id // "unknown") ]
      | unique | length' <"$raw_out" 2>/dev/null)"
    if [[ ! "$violation_events" =~ ^[0-9]+$ ]]; then
      violation_events="$(jq -Rrn '[inputs | fromjson? // empty | select(type=="object" and .role=="tool" and (.content? | type)=="string" and (.content | test("operation not permitted|not a git repository"; "i"))) | (.tool_call_id // "unknown")] | unique | length' <"$raw_out" 2>/dev/null)"
      violation_events="${violation_events:-0}"
    fi
    violation_stderr_hits="$(grep -a -c -i -e 'Operation not permitted' -e 'not a git repository' "$raw_err" 2>/dev/null || true)"
    violation_log_hits="$( { grep -a -c -i -e 'Operation not permitted' -e 'not a git repository' "$raw_out" 2>/dev/null; printf '%s\n' "$violation_stderr_hits"; } | awk '{s += $1} END {print s+0}')"
    scope_violation_attempts="$violation_events"
    # denials that only reached stderr (no tool event) still count, once per line
    [[ "$scope_violation_attempts" == "0" ]] && scope_violation_attempts="$violation_stderr_hits"
  fi

  if [[ -z "$quarantine_note" ]]; then
    final_text="$(jq -Rrn '[inputs | fromjson? // empty | select(type=="object" and .role=="assistant" and (.content? | type)=="string" and (.content | length) > 0) | .content] | last // empty' <"$raw_out" 2>/dev/null)"
    if [[ -n "$final_text" ]]; then
      extraction_status="extracted from stream-json (last assistant text message)"
    else
      extraction_status="unverifiable (no parseable final assistant message; inspect the raw stream-json below)"
    fi
    # Prefer the machine contract whenever a valid fenced JSON block exists.
    # Do not pipe it through head(1): pretty-printed JSON is multi-line.
    verdict_block="$(printf '%s\n' "$final_text" | perl -0777 -ne 'if (/```json[[:space:]]*\n(.*?)\n[[:space:]]*```/s) { print $1 }')"
    schema_verdict=""
    if [[ -n "$verdict_block" ]]; then
      schema_verdict="$(printf '%s\n' "$verdict_block" | jq -er 'if (.verdict? | type) == "string" and (.verdict | test("^(PASS|NEEDS_ATTENTION|BLOCKED)$")) and ((.findings? // []) | type) == "array" and all(.findings[]?; ((.severity? // "") | test("^(P0|P1|P2|P3)$"))) then .verdict else error end' 2>/dev/null || true)"
    fi
    if [[ -n "$schema_verdict" ]]; then
      verdict="$schema_verdict"
      verdict_contract="json-schema"
    else
      verdict="$(printf '%s\n' "$final_text" | grep -Eio 'Verdict[^A-Za-z]*(PASS|NEEDS_ATTENTION|BLOCKED)' | grep -Eio '(PASS|NEEDS_ATTENTION|BLOCKED)' | head -1 || true)"
      if [[ -z "$verdict" ]]; then
        # Markdown-header form, allowing a short parenthetical explanation.
        verdict="$(printf '%s\n' "$final_text" | perl -0777 -ne 'if (/Verdict[^\n]*\n(?:[^\n]*\n){0,2}\s*(?:\*\*|##[[:space:]]*)?(PASS|NEEDS_ATTENTION|BLOCKED)\b/i) { print uc($1) }' | head -1)"
      fi
      verdict="${verdict:-not found in final message (heuristic; confirm manually)}"
      verdict_contract="none"
      [[ "$verdict" != "not found"* ]] && verdict_contract="text-heuristic"
    fi
    final_verdict="$verdict"
    tool_summary="$(jq -Rrn '[inputs | fromjson? // empty | select(type=="object" and .role=="assistant" and .tool_calls) | .tool_calls[].function.name] | group_by(.) | map("\(.[0]) x\(length)") | join(", ")' <"$raw_out" 2>/dev/null)"
    tool_summary="${tool_summary:-none recorded}"
    session_id="$(jq -Rrn '[inputs | fromjson? // empty | select(type=="object" and .role=="meta" and (.session_id? != null)) | .session_id] | last // empty' <"$raw_out" 2>/dev/null)"
    session_id="${session_id:-not recorded}"
  fi

  gate_reasons=()
  [[ -n "$quarantine_note" ]] && gate_reasons+=("secret-quarantine")
  [[ "$secret_scan_failed" == true ]] && gate_reasons+=("secret-scan-failure")
  [[ "$empty_output" == "1" ]] && gate_reasons+=("empty-output")
  [[ "$final_timed_out" != "false" ]] && gate_reasons+=("timeout")
  case "$final_status" in
    INTERRUPTED*) gate_reasons+=("interrupted") ;;
    FAILED*)
      if [[ "$runner_internal" == "1" ]]; then
        gate_reasons+=("runner-failure")
      else
        [[ -n "$provider_error" ]] && gate_reasons+=("provider-api-error")
        gate_reasons+=("nonzero-review-exit")
      fi
      ;;
  esac
  [[ "$verdict" == "not found"* ]] && gate_reasons+=("no-verdict")
  (( scope_violation_attempts > 0 )) && gate_reasons+=("scope-violation-attempt")
  [[ "$scope_mode" == "strict-unenforced" ]] && gate_reasons+=("strict-scope-unenforced")
  gate_eligible=true
  (( ${#gate_reasons[@]} > 0 )) && gate_eligible=false

  # place raw evidence in the sidecar before any paths are published
  if [[ -n "$quarantine_note" ]]; then
    q_out="$sidecar_dir/stdout.quarantined.jsonl"
    q_err="$sidecar_dir/stderr.quarantined.log"
    if mv "$raw_out" "$q_out" 2>/dev/null; then chmod 600 "$q_out" 2>/dev/null || true; fi
    if mv "$raw_err" "$q_err" 2>/dev/null; then chmod 600 "$q_err" 2>/dev/null || true; fi
    quarantined_files="$q_out $q_err"
  else
    cp "$raw_out" "$sidecar_dir/stdout.jsonl" 2>/dev/null || true
    cp "$raw_err" "$sidecar_dir/stderr.log" 2>/dev/null || true
  fi

  # git state sidecars (best effort; only the normal path has after-state)
  if [[ -n "$after_head" ]]; then
    jq -n --arg head "$before_head" --arg index_fp "${before_index_fp:-}" --arg status_fp "${before_status_fp:-}" --arg worktree_fp "${before_worktree_fp:-}" --arg staged_fp "${before_staged_fp:-}" '{head:$head,index_fingerprint:$index_fp,status_fingerprint:$status_fp,worktree_fingerprint:$worktree_fp,staged_fingerprint:$staged_fp}' >"$sidecar_dir/git-before.json" 2>/dev/null || true
    jq -n --arg head "$after_head" --arg index_fp "${after_index_fp:-}" --arg status_fp "${after_status_fp:-}" --arg worktree_fp "${after_worktree_fp:-}" --arg staged_fp "${after_staged_fp:-}" '{head:$head,index_fingerprint:$index_fp,status_fingerprint:$status_fp,worktree_fingerprint:$worktree_fp,staged_fingerprint:$staged_fp}' >"$sidecar_dir/git-after.json" 2>/dev/null || true
    printf '%s\n' "$before" >"$sidecar_dir/git-before.status" 2>/dev/null || true
    printf '%s\n' "$after_review" >"$sidecar_dir/git-after.status" 2>/dev/null || true
  fi

  {
    printf '## Warnings\n\n'
    [[ -n "$mutation_warning" ]] && printf '%s' "$mutation_warning"
    [[ -n "$resource_warning" ]] && printf '%s' "$resource_warning"
    [[ -n "$empty_warning" ]] && printf '%s' "$empty_warning"
    if (( scope_violation_attempts > 0 )); then
      printf '> [!WARNING]\n> Strict scope: %s out-of-scope read attempt(s) were denied by the sandbox (%s raw log hits across both streams). Out-of-scope content did not enter the review stream; count the attempt against gate eligibility.\n\n' "$scope_violation_attempts" "$violation_log_hits"
    fi
    if [[ -n "$quarantine_note" ]]; then
      printf '> [!WARNING]\n> Raw output matched secret patterns (%s) and was quarantined. Only this summary is published; the raw files are retained outside the artifact for manual handling: %s. Treat any exposed credential as leaked and rotate it. Retained raw files are not durable evidence: review them within 7 days, then delete them after the credential review and rotation; do not delete them before that review.\n\n' "$quarantine_note" "$quarantined_files"
    fi
    [[ -z "$mutation_warning" && -z "$resource_warning" && -z "$empty_warning" && -z "$quarantine_note" && "$scope_violation_attempts" == "0" ]] && printf 'None.\n\n'
    [[ -n "$final_note" ]] && printf '> [!NOTE]\n> %s\n\n' "$final_note"

    printf '## Execution\n\n'
    printf -- '- Command: `kimi -m %s --output-format stream-json --skills-dir <empty run dir> -p <prompt>`\n' "$model"
    printf -- '- Working directory: `%s`\n- Kimi CLI: `%s`\n- Runner: `run_review.sh v%s`\n' "$PWD" "$(kimi --version 2>&1)" "$RUNNER_VERSION"
    printf -- '- Resolved model: `%s`\n- Provider identity (catalog): `%s`\n' "$model" "$provider_identity"
    printf -- '- Started (UTC): `%s`\n- Finished (UTC): `%s`\n- Duration: `%s`\n' "$started_at" "$finished_at" "$duration_ms_disp"
    printf -- '- Exit code: `%s`\n- Timed out: `%s`\n- Termination signal: `%s`\n' "$final_exit_code" "$final_timed_out" "$final_signal"
    printf -- '- Timeout policy: outer %ss (kill-after 5s); provider catalog %ss\n- Timeout command: `%s`\n' "$timeout_seconds" "$provider_timeout_seconds" "$timeout_command_desc"
    printf -- '- Isolation: %s\n' "$isolation"
    if (( ${#runner[@]} > 0 )); then
      printf -- '- Effective sandbox parameters:\n\n```text\n'
      printf '%s\n' "${runner[@]}"
      printf '```\n'
    else
      printf -- '- Effective sandbox parameters: none (prompt-only run)\n'
    fi
    printf -- '- Diff fallback snapshot: `%s` (temporary; removed after artifact creation)\n- Snapshot SHA-256: `%s`\n' "$diff_snapshot" "${snapshot_sha:-unavailable}"
    printf -- '- Visual preflight: %s\n- Mutation check: %s\n- Wrapper PID: `%s`\n- Process release: %s\n' "$visual_preflight" "$mutation_check" "$review_pid" "$process_release"
    printf -- '- Kimi session: `%s`\n' "$session_id"
    printf -- '- Scope mode: `%s` (violation attempts: `%s`)\n' "$scope_mode" "$scope_violation_attempts"
    printf -- '- Review target: `%s`\n' "$review_target"
    if [[ "$review_target" == "sanitized-projection" ]]; then
      printf -- '- Projection manifest: `./%s/projection.json` (source/projection SHA-256 and per-rule replacement counts)\n' "$(basename "$sidecar_dir")"
    fi
    printf -- '- Gate eligible: `%s`' "$gate_eligible"
    if (( ${#gate_reasons[@]} > 0 )); then
      printf ' (reasons: %s)' "${gate_reasons[*]}"
    fi
    printf '\n- Execution record (JSON): `./%s/execution.json`\n\n' "$(basename "$sidecar_dir")"

    if [[ -z "$quarantine_note" ]]; then
      verdict_label="heuristic"
      [[ "$verdict_contract" == "json-schema" ]] && verdict_label="schema"
      printf '## Result Extraction\n\n- Verdict (%s): `%s`\n- Verdict contract: `%s`\n- Extraction status: %s\n- Tool-use summary: %s\n\n' "$verdict_label" "$verdict" "$verdict_contract" "$extraction_status" "$tool_summary"
      printf '## Final Assistant Message\n\n```text\n%s\n```\n\n' "$final_text"
      printf '## Raw Kimi stdout (stream-json)\n\n```json\n'; cat "$raw_out"; printf '\n```\n\n'
      printf '## Kimi stderr\n\n```text\n'
      [[ -s "$raw_err" ]] && cat "$raw_err" || printf '(empty)\n'
      printf '```\n\n'
    else
      printf '## Result Extraction\n\nSkipped: raw output quarantined after secret-pattern match. Verdict, tool-use summary, and raw sections are withheld.\n\n'
    fi

    printf '## Process Evidence\n\n```text\n'
    if [[ -s "$review_processes" ]]; then
      LC_ALL=C sort -u -k1,1n "$review_processes"
    else
      printf '(no process evidence recorded)\n'
    fi
    printf '```\n\n'
  } >>"$artifact" || printf 'Unable to append evidence sections: %s\n' "$artifact" >&2

  remove_temp_files
  temporary_release="all review temporary files removed"
  local temp_path
  for temp_path in "$raw_out" "$raw_err" "$prompt" "$diff_snapshot"; do
    if [[ -n "$temp_path" && -e "$temp_path" ]]; then
      temporary_release="temporary file remains: $temp_path"
    fi
  done
  write_execution_json "$final_status" || printf 'Unable to write execution.json sidecar for %s\n' "$artifact" >&2

  durable_copy_result=""
  if [[ -n "$durable_dir" ]]; then
    durable_sidecar="$durable_dir/$(basename "$sidecar_dir")"
    if mkdir -p "$durable_dir" && cp "$artifact" "$durable_dir/" && mkdir -p "$durable_sidecar"; then
      durable_copy_result="ok"
      # copy the sidecar entry by entry: quarantined raw streams must never
      # reach a repo-governed (committable/pushable) directory; they are
      # replaced by a plain-text placeholder note
      for sidecar_path in "$sidecar_dir"/*; do
        [[ -e "$sidecar_path" ]] || continue
        case " $quarantined_files " in
          *" $sidecar_path "*) continue ;;
        esac
        cp -R "$sidecar_path" "$durable_sidecar/" 2>/dev/null || durable_copy_result="failed"
      done
      if [[ -n "$quarantined_files" ]]; then
        printf 'Raw output matched secret patterns and was quarantined. The quarantined raw streams are intentionally excluded from this durable copy and are retained only in the runtime sidecar (not durable evidence): %s\n' "$quarantined_files" \
          >"$durable_sidecar/QUARANTINED.txt" 2>/dev/null || durable_copy_result="failed"
      fi
    fi
    if [[ "$durable_copy_result" != "ok" ]]; then
      durable_copy_result="failed"
      gate_reasons+=("durable-copy-failure")
      gate_eligible=false
      evidence_class="durable gate evidence copy FAILED to $durable_dir; runtime diagnostic only"
      update_line '- Evidence class: ' "- Evidence class: $evidence_class" || true
      # overwrite any partially copied markdown so it cannot claim durable status
      if [[ -f "$durable_dir/$(basename "$artifact")" ]]; then
        cp "$artifact" "$durable_dir/" 2>/dev/null || true
      fi
      write_execution_json "$final_status" || printf 'Unable to write execution.json sidecar for %s\n' "$artifact" >&2
      if [[ -d "$durable_sidecar" ]]; then
        cp "$sidecar_dir/execution.json" "$durable_sidecar/" 2>/dev/null || true
      fi
    fi
  fi
  {
    printf '## Resource Cleanup\n\n- Process release: %s\n- Temporary release: %s\n' "$process_release" "$temporary_release"
    if [[ -n "$quarantined_files" ]]; then
      printf -- '- Quarantined (retained) raw files: %s\n' "$quarantined_files"
      if [[ -n "$durable_dir" && "$durable_copy_result" == "ok" ]]; then
        printf -- '- Durable copy note: quarantined raw streams were excluded from the durable sidecar (see QUARANTINED.txt there)\n'
      fi
    fi
    if [[ -n "$durable_dir" ]]; then
      if [[ "$durable_copy_result" == "ok" ]]; then
        printf -- '- Durable gate copy: `%s/%s` (with execution.json sidecar)\n' "$(canonical_dir "$durable_dir")" "$(basename "$artifact")"
      else
        printf -- '- Durable gate copy: FAILED to write to `%s`; artifact marked gate-ineligible (durable-copy-failure)\n' "$durable_dir"
      fi
    fi
  } >>"$artifact" || printf 'Unable to append cleanup evidence: %s\n' "$artifact" >&2
  if [[ -n "$durable_dir" && -f "$durable_dir/$(basename "$artifact")" ]]; then
    # the first copy predates the Resource Cleanup section; refresh it so the
    # durable markdown is self-contained
    cp "$artifact" "$durable_dir/" 2>/dev/null || true
  fi
  finalized=1
}

finalize_interrupted() {
  local sig="$1" sig_num
  [[ "$finalized" == "1" ]] && return 0
  case "$sig" in
    INT)  sig_num=2 ;;
    TERM) sig_num=15 ;;
    HUP)  sig_num=1 ;;
    *)    sig_num=0 ;;
  esac
  trap - EXIT INT TERM HUP
  stop_review_processes
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  end_ms="$(now_ms)"
  duration_ms_disp="$(( end_ms - start_ms )) ms (~$(( (end_ms - start_ms) / 1000 ))s)"
  final_status="INTERRUPTED (SIG$sig)"
  final_exit_code="none (runner received SIG$sig)"
  final_timed_out="false"
  final_signal="SIG$sig (external)"
  final_note="The runner was interrupted before Kimi returned. This artifact preserves partial evidence; the review is incomplete. Do not treat an interrupted run as a timeout failure, and do not terminate review runs before the ${timeout_seconds}s outer timeout unless there is a provider error, a permission wait, or a resource anomaly."
  process_release="interrupted run: review process tree terminated by runner"
  resource_warning=""
  mutation_check="not evaluated (interrupted run)"
  mutation_warning=""
  if after_review="$(git status --porcelain=v1 2>/dev/null)" && [[ "$before" == "$after_review" ]]; then
    mutation_check="working tree unchanged during Kimi review"
  fi
  append_evidence_and_cleanup
  exit $((128 + sig_num))
}

# ---------- launch ----------

if ! before="$(git status --porcelain=v1)"; then
  die 'Unable to capture the pre-review git status.' 3
fi
if ! before_head="$(git rev-parse HEAD 2>/dev/null)"; then
  before_head="unborn (no commits)"
fi
before_index_fp="$(git ls-files --stage | hash_stdin)"
before_status_fp="$(printf '%s\n' "$before" | hash_stdin)"
before_worktree_fp="$(git -c diff.external= -c diff.relative=false diff --no-ext-diff --no-textconv | hash_stdin)"
before_staged_fp="$(git -c diff.external= -c diff.relative=false diff --no-ext-diff --no-textconv --cached | hash_stdin)"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
start_ms="$(now_ms)"
prompt_content="$(<"$prompt")"
gtimeout_bin="$(command -v gtimeout 2>/dev/null || true)"
timeout_bin=""
if [[ -z "$gtimeout_bin" ]]; then
  timeout_bin="$(command -v timeout 2>/dev/null || true)"
fi

on_exit() {
  local code=$?
  if [[ "$finalized" != "1" ]]; then
    stop_review_processes
    if [[ "$artifact_created" == "1" ]]; then
      finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      end_ms="$(now_ms)"
      duration_ms_disp="$(( end_ms - start_ms )) ms"
      final_status="FAILED (runner exited unexpectedly, exit $code)"
      runner_internal=1
      final_exit_code="$code"
      final_timed_out="unknown"
      final_signal="unknown"
      final_note="The runner exited unexpectedly before finalizing. Evidence sections are best-effort."
      process_release="runner died unexpectedly; review tree terminated by EXIT trap"
      resource_warning=""
      mutation_check="not evaluated (runner failure)"
      mutation_warning=""
      append_evidence_and_cleanup || true
    fi
    remove_temp_files
  fi
}
trap on_exit EXIT
trap 'finalize_interrupted INT' INT
trap 'finalize_interrupted TERM' TERM
trap 'finalize_interrupted HUP' HUP

review_command=(${runner[@]+"${runner[@]}"} kimi -m "$model" --output-format stream-json -p "$prompt_content")
# suppress kimi's user+project skills auto-discovery: a reviewed repository can
# ship project skills whose instructions steer the reviewer, and Kimi write
# tools still execute in -p mode (the sandbox is the only write barrier). The
# empty runner-owned directory replaces both discovery surfaces entirely.
empty_skills_dir="$run_tmp/empty-skills-dir"
if ! mkdir -p "$empty_skills_dir"; then
  die 'Unable to create the empty skills directory.' 3
fi
review_command+=(--skills-dir "$empty_skills_dir")
timeout_impl="native-watchdog"
if [[ -n "$gtimeout_bin" ]]; then
  review_command=("$gtimeout_bin" -k 5s "${timeout_seconds}s" "${review_command[@]}")
  timeout_impl="gtimeout"
elif [[ -n "$timeout_bin" ]]; then
  review_command=("$timeout_bin" -k 5s "${timeout_seconds}s" "${review_command[@]}")
  timeout_impl="timeout"
fi
if [[ "$scope_mode" == "strict" ]]; then
  (cd "$strict_cwd" && TMPDIR="$run_tmp" exec "${review_command[@]}") >"$raw_out" 2>"$raw_err" &
else
  "${review_command[@]}" >"$raw_out" 2>"$raw_err" &
fi
review_pid=$!
record_review_tree "$review_pid"
monitor_review_tree "$review_pid" &
monitor_pid=$!
# Without GNU timeout the documented outer timeout must still hold: a native
# watchdog terminates the review tree after ${timeout_seconds}s (TERM, then
# KILL after a 5s grace) and marks the run as timed out via a marker file.
watchdog_pid=""
if [[ "$timeout_impl" == "native-watchdog" ]]; then
  (
    sleep "$timeout_seconds"
    if kill -0 "$review_pid" 2>/dev/null; then
      : >"$run_tmp/timeout.fired" 2>/dev/null || true
      terminate_review_tree "$review_pid" TERM
      sleep 5
      terminate_review_tree "$review_pid" KILL
    fi
  ) &
  watchdog_pid=$!
fi
exit_code=0
wait "$review_pid" || exit_code=$?
if [[ -n "$watchdog_pid" ]]; then
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  watchdog_pid=""
fi
native_timeout_fired=0
[[ -f "$run_tmp/timeout.fired" ]] && native_timeout_fired=1
wait "$monitor_pid" 2>/dev/null || true
monitor_pid=""
sleep 1

# ---------- terminal state ----------

finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
end_ms="$(now_ms)"
duration_ms_disp="$(( end_ms - start_ms )) ms (~$(( (end_ms - start_ms) / 1000 ))s)"

final_timed_out="false"
final_signal="none"
if [[ "$exit_code" -eq 124 || ( "$native_timeout_fired" == "1" && "$exit_code" != "0" ) ]]; then
  final_timed_out="true"
  final_signal="SIGTERM (outer timeout)"
elif [[ "$exit_code" -eq 137 && ( "$native_timeout_fired" == "1" || $(( (end_ms - start_ms) / 1000 )) -ge "$timeout_seconds" ) ]]; then
  final_timed_out="true (killed after grace period)"
  final_signal="SIGKILL (outer timeout kill-after)"
elif [[ "$exit_code" -gt 128 ]]; then
  final_signal="SIG$(kill -l $((exit_code - 128)) 2>/dev/null || printf '%s' $((exit_code - 128))) (external)"
fi

if [[ "$final_timed_out" == "false" ]]; then
  if [[ "$exit_code" -eq 0 ]]; then
    final_status="COMPLETED"
    final_note=""
  else
    final_status="FAILED"
    if grep -aEq 'provider\.api_error|usage limit|status code 401|status code 403|authentication failed|insufficient quota|quota exceeded' "$raw_err" 2>/dev/null; then
      provider_error="provider-api-error"
    fi
    final_note="The review process exited non-zero (exit $exit_code) before producing a final verdict; classify it as a review/provider failure, not a completed review, and run the configured fallback for the same scope."
  fi
else
  final_status="TIMED_OUT"
  final_note="The review hit the ${timeout_seconds}s outer timeout and is incomplete. Split an oversized scope rather than shortening the timeout; minutes without stdout are normal and are not a hang signal."
fi
final_exit_code="$exit_code"

remaining_review_processes=""
while IFS=$'\t' read -r tracked_pid tracked_identity; do
  [[ -n "$tracked_pid" ]] || continue
  if kill -0 "$tracked_pid" 2>/dev/null; then
    current_identity="$(process_identity "$tracked_pid" 2>/dev/null || true)"
    if [[ -n "$tracked_identity" && "$current_identity" == "$tracked_identity" ]]; then
      remaining_review_processes="${remaining_review_processes}${remaining_review_processes:+ }$tracked_pid"
    else
      mismatch_pids="${mismatch_pids}${mismatch_pids:+ }$tracked_pid"
    fi
  fi
done <"$review_processes"
if [[ -z "$pgrep_path" ]]; then
  process_release="wrapper PID $review_pid exited; descendant verification unavailable because pgrep is missing"
  resource_warning=$'> [!WARNING]\n> The review wrapper exited, but descendant verification was unavailable because pgrep is missing. Treat resource release as unverified.\n\n'
elif [[ ! -s "$review_processes" ]]; then
  process_release="process-tree evidence is empty; resource release unverified"
  resource_warning=$'> [!WARNING]\n> Process-tree evidence could not be recorded. Treat resource release as unverified.\n\n'
elif [[ -n "$remaining_review_processes" ]]; then
  process_release="tracked review PIDs remain after completion: $remaining_review_processes"
  resource_warning=$'> [!WARNING]\n> One or more processes from this review tree remain after completion. Inspect the recorded PID tree; do not terminate unrelated processes.\n\n'
else
  process_release="wrapper PID $review_pid and all descendants observed in sampled tree evidence exited"
  resource_warning=""
fi
if [[ -n "$mismatch_pids" ]]; then
  process_release="$process_release; PID reuse or identity change observed for: $mismatch_pids (not counted as remaining)"
fi

mutation_warning=""
if ! after_review="$(git status --porcelain=v1)"; then
  mutation_check="unable to capture post-review git status"
  mutation_warning=$'> [!WARNING]\n> The post-review git status could not be captured. Treat the review as incomplete and inspect the working tree manually.\n\n'
else
  if ! after_head="$(git rev-parse HEAD 2>/dev/null)"; then
    after_head="unborn (no commits)"
  fi
  after_index_fp="$(git ls-files --stage | hash_stdin)"
  after_status_fp="$(printf '%s\n' "$after_review" | hash_stdin)"
  after_worktree_fp="$(git -c diff.external= -c diff.relative=false diff --no-ext-diff --no-textconv | hash_stdin)"
  after_staged_fp="$(git -c diff.external= -c diff.relative=false diff --no-ext-diff --no-textconv --cached | hash_stdin)"
  changed_fields=()
  [[ "$before_head" != "$after_head" ]] && changed_fields+=("head")
  [[ "$before_index_fp" != "$after_index_fp" ]] && changed_fields+=("index")
  [[ "$before_status_fp" != "$after_status_fp" ]] && changed_fields+=("status")
  [[ "$before_worktree_fp" != "$after_worktree_fp" ]] && changed_fields+=("worktree-diff")
  [[ "$before_staged_fp" != "$after_staged_fp" ]] && changed_fields+=("staged-diff")
  mutation_changed="$(printf '%s\n' "${changed_fields[@]+"${changed_fields[@]}"}")"
  mutation_detected_bool=false
  (( ${#changed_fields[@]} > 0 )) && mutation_detected_bool=true
  if [[ "$mutation_detected_bool" == "false" ]]; then
    mutation_check="working tree unchanged during Kimi review (HEAD $before_head; index/status fingerprints unchanged; equality is not complete mutation proof)"
  else
    changed_paths="$(comm -3 <(printf '%s\n' "$before" | LC_ALL=C sort) <(printf '%s\n' "$after_review" | LC_ALL=C sort) | sed 's/^[\t]*//' | head -20)"
    head_note=""
    if [[ "$before_head" != "$after_head" ]]; then
      head_note=" HEAD moved $before_head -> $after_head, which indicates a concurrent commit rather than a review-process edit."
    fi
    mutation_check="working tree changed during Kimi review (changed: ${changed_fields[*]}); defensive evidence only, may be concurrent user or session activity; do not revert automatically.${head_note}"
    mutation_warning="> [!WARNING]\n> The working tree changed during the Kimi process (changed: ${changed_fields[*]}).$head_note\n> Changed status lines (truncated at 20):\n>\n"
    while IFS= read -r change_line; do
      [[ -n "$change_line" ]] && mutation_warning="${mutation_warning}> \`${change_line}\`\n"
    done <<<"$changed_paths"
    mutation_warning="${mutation_warning}\n"
  fi
fi

append_evidence_and_cleanup

printf 'Kimi review artifact: %s\nStatus: %s\nReview exit code: %s\nProcess release: %s\n' "$artifact" "$final_status" "$final_exit_code" "$process_release"
if [[ -n "$durable_dir" ]]; then
  printf 'Durable gate copy: %s/%s\n' "$(canonical_dir "$durable_dir")" "$(basename "$artifact")"
fi
if [[ "$require_verdict" == "1" && "$gate_eligible" != "true" ]]; then
  printf 'Review is not gate-eligible: %s\n' "${gate_reasons[*]}" >&2
  exit 4
fi
exit 0
