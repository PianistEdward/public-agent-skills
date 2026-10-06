#!/usr/bin/env bash
set -u
# review artifacts may contain sensitive findings: keep everything the runner
# creates private even when a gate path is world-traversable (the omp sibling
# does the same)
umask 077

runner_version="1.7.3"
default_timeout="30m"
repo_process_filters_detected=false
repo_process_filters_origin=""
review_schema='{"type":"object","properties":{"verdict":{"type":"string","enum":["PASS","NEEDS_ATTENTION","BLOCKED"]},"findings":{"type":"array","items":{"type":"object","properties":{"severity":{"type":"string"},"file":{"type":"string"},"line":{"type":"integer","minimum":1},"issue":{"type":"string"},"recommendation":{"type":"string"}},"required":["severity","issue","recommendation"],"additionalProperties":false}},"caveats":{"type":"array","items":{"type":"string"}},"next_steps":{"type":"array","items":{"type":"string"}}},"required":["verdict","findings","caveats","next_steps"],"additionalProperties":false}'

repo_arg="$PWD"
scope=""
original_task=""
slug=""
artifact_arg=""
timeout_value="$default_timeout"
fallback_model=""
safe_mode=true
no_tools=false
debug_mode=false
watchdog_enabled=false
prompt_path_unsafe=false
artifact_seen=0
slug_seen=0
task_seen=0
fallback_seen=0

usage() {
  cat <<'USAGE'
Usage: run_review.sh --scope <description> [options]

Options:
  --repo <path>             Repository to review (default: current directory)
  --scope <description>     Exact review scope, such as HEAD~2..HEAD or named files
  --task <text>             Original review request or special review focus
  --slug <slug>             Artifact filename slug
  --artifact <path>         Explicit markdown artifact path
  --timeout <duration>      GNU timeout duration (default: 30m)
  --fallback-model <models> Claude print-mode fallback model list
  --safe-mode               Disable Claude customizations (default: on)
  --no-safe-mode            Re-enable Claude customizations (project
                            settings/hooks/MCP/CLAUDE.md) — trusted repos only
  --no-tools                Run Claude with --tools "" (no tools at all) for
                            untrusted or archived repositories
  --debug                   Preserve Claude debug output and session recovery data
  --watchdog                Opt in to CLAUDE_CODE_RETRY_WATCHDOG=1
  -h, --help                Show this help
USAGE
}

die() {
  printf 'ask-claude review: %s\n' "$1" >&2
  exit "${2:-64}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || die "--repo requires a value"
      repo_arg="$2"
      shift 2
      ;;
    --scope)
      [[ $# -ge 2 ]] || die "--scope requires a value"
      scope="$2"
      shift 2
      ;;
    --task)
      [[ $# -ge 2 ]] || die "--task requires a value"
      original_task="$2"
      task_seen=1
      shift 2
      ;;
    --slug)
      [[ $# -ge 2 ]] || die "--slug requires a value"
      slug="$2"
      slug_seen=1
      shift 2
      ;;
    --artifact)
      [[ $# -ge 2 ]] || die "--artifact requires a value"
      artifact_arg="$2"
      artifact_seen=1
      shift 2
      ;;
    --timeout)
      [[ $# -ge 2 ]] || die "--timeout requires a value"
      timeout_value="$2"
      shift 2
      ;;
    --fallback-model)
      [[ $# -ge 2 ]] || die "--fallback-model requires a value"
      fallback_model="$2"
      fallback_seen=1
      shift 2
      ;;
    --safe-mode)
      safe_mode=true
      shift
      ;;
    --no-safe-mode)
      safe_mode=false
      shift
      ;;
    --no-tools)
      no_tools=true
      shift
      ;;
    --debug)
      debug_mode=true
      shift
      ;;
    --watchdog)
      watchdog_enabled=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ -n "$scope" ]] || die "--scope must be non-empty"
# empty values for value-bearing options must fail loudly: `--artifact ""`
# would otherwise silently select the default runtime path (a gate-evidence
# request that "succeeds" with no evidence at the expected location)
[[ -n "$artifact_arg" || "$artifact_seen" == 0 ]] || die "--artifact must be non-empty" 64
[[ -n "$slug" || "$slug_seen" == 0 ]] || die "--slug must be non-empty" 64
[[ -n "$original_task" || "$task_seen" == 0 ]] || die "--task must be non-empty" 64
[[ -n "$fallback_model" || "$fallback_seen" == 0 ]] || die "--fallback-model must be non-empty" 64
original_task="${original_task:-Review $scope}"
[[ "$timeout_value" =~ ^([1-9][0-9]*([.][0-9]+)?|0[.][0-9]*[1-9][0-9]*)[smhd]$ ]] || die "invalid timeout '$timeout_value' (use values such as 30m, 90s, or 0.5s)"

# milliseconds for the validated duration; the exit-137 kill-after
# classification compares elapsed wall time against this
duration_to_ms() {
  local value="$1" number="${value%[smhd]}" unit="${value//[0-9.]/}" unit_ms=1000
  case "$unit" in
    s) unit_ms=1000 ;;
    m) unit_ms=60000 ;;
    h) unit_ms=3600000 ;;
    d) unit_ms=86400000 ;;
  esac
  awk -v n="$number" -v u="$unit_ms" 'BEGIN { printf "%d\n", n * u }'
}
timeout_value_to_ms="$(duration_to_ms "$timeout_value")"

git_bin="${ASK_CLAUDE_GIT_BIN:-$(command -v git 2>/dev/null || true)}"
claude_bin="${ASK_CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}"
jq_bin="${ASK_CLAUDE_JQ_BIN:-$(command -v jq 2>/dev/null || true)}"
perl_bin="${ASK_CLAUDE_PERL_BIN:-$(command -v perl 2>/dev/null || true)}"
grep_bin="${ASK_CLAUDE_GREP_BIN:-$(command -v grep 2>/dev/null || true)}"
ps_bin="${ASK_CLAUDE_PS_BIN:-$(command -v ps 2>/dev/null || true)}"
pgrep_bin="${ASK_CLAUDE_PGREP_BIN:-$(command -v pgrep 2>/dev/null || true)}"
mktemp_bin="${ASK_CLAUDE_MKTEMP_BIN:-$(command -v mktemp 2>/dev/null || true)}"
if [[ -n "${ASK_CLAUDE_TIMEOUT_BIN:-}" ]]; then
  timeout_bin="$ASK_CLAUDE_TIMEOUT_BIN"
elif command -v gtimeout >/dev/null 2>&1; then
  timeout_bin="$(command -v gtimeout)"
else
  timeout_bin="$(command -v timeout 2>/dev/null || true)"
fi
# every git invocation (preflight probes, snapshots) is bounded by this
# binary: a host without it must fail closed here, not hang inside
# `rev-parse` on a blocking config include later
[[ -n "$timeout_bin" && -x "$timeout_bin" ]] || die "GNU timeout/gtimeout is required and was not found" 69
# behavioral probe: a non-GNU binary (busybox, Windows timeout.exe) cannot
# parse -k/-s and would surface as a wrong "not a Git repository" diagnosis
"$timeout_bin" -k 1s 5s true >/dev/null 2>&1 || die "GNU timeout/gtimeout is required (found: $timeout_bin, not GNU-compatible)" 69

hash_mode=""
if [[ -n "${ASK_CLAUDE_HASH_BIN:-}" ]]; then
  hash_bin="$ASK_CLAUDE_HASH_BIN"
  hash_mode="${ASK_CLAUDE_HASH_MODE:-shasum}"
elif command -v shasum >/dev/null 2>&1; then
  hash_bin="$(command -v shasum)"
  hash_mode="shasum"
elif command -v sha256sum >/dev/null 2>&1; then
  hash_bin="$(command -v sha256sum)"
  hash_mode="sha256sum"
else
  hash_bin=""
fi

[[ -n "$git_bin" && -x "$git_bin" ]] || die "git is required and was not found" 69
# every git invocation is bounded: `git config` follows include.path chains
# and rev-parse parses merged config, so a blocking include/FIFO must not
# hang preflight (timeout_bin is resolved above, before first use)
# timeout_bin is required (died 69 above if missing/non-GNU): every git
# invocation is bounded
probe_git() { "$timeout_bin" -k 5s 30 "$git_bin" "$@"; }
[[ -d "$repo_arg" ]] || die "repository directory does not exist: $repo_arg" 66
repo_root="$(cd "$repo_arg" 2>/dev/null && probe_git rev-parse --show-toplevel 2>/dev/null)" || die "review must run inside a Git repository" 66
repo_root="$(cd "$repo_root" 2>/dev/null && pwd -P)" || die "unable to resolve repository path" 66
git_dir="$(probe_git -C "$repo_root" rev-parse --absolute-git-dir 2>/dev/null)" || die "unable to resolve Git directory" 66
git_dir="$(cd "$git_dir" 2>/dev/null && pwd -P)" || die "unable to resolve Git directory path" 66
# linked worktrees: the shared directory (config/hooks/refs) sits outside the
# per-worktree git dir and needs its own write deny, or a worktree whose main
# repo lives under an allowed write root could have its .git written
git_common_dir="$(probe_git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || printf '%s' "$git_dir")"
git_common_dir="$(cd "$git_common_dir" 2>/dev/null && pwd -P)" || git_common_dir="$git_dir"
skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp_dir="$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)" || die "unable to resolve TMPDIR" 73

slug="${slug:-review}"
[[ "$slug" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$ ]] || die "invalid slug '$slug' (1-80 chars, must start with a letter or digit, then letters, digits, dots, underscores, or hyphens)" 64

resolve_future_file() {
  local candidate="$1" parent leaf component suffix="" resolved_parent next_parent
  [[ "$candidate" != *'/../'* && "$candidate" != */.. && "$candidate" != ../* ]] || return 1
  parent="$(dirname "$candidate")"
  leaf="$(basename "$candidate")"
  [[ -n "$leaf" && "$leaf" != "." && "$leaf" != ".." ]] || return 1
  while [[ ! -d "$parent" ]]; do
    [[ ! -e "$parent" ]] || return 1
    component="$(basename "$parent")"
    [[ -n "$component" && "$component" != "." && "$component" != ".." ]] || return 1
    suffix="/$component$suffix"
    next_parent="$(dirname "$parent")"
    [[ "$next_parent" != "$parent" ]] || return 1
    parent="$next_parent"
  done
  resolved_parent="$(cd "$parent" 2>/dev/null && pwd -P)" || return 1
  printf '%s%s/%s\n' "$resolved_parent" "$suffix" "$leaf"
}

path_is_within() {
  [[ "$1" == "$2" || "$1" == "$2"/* ]]
}

artifact_dir_is_safe() {
  local resolved_dir
  [[ -d "$artifact_dir" && ! -L "$artifact_dir" ]] || return 1
  resolved_dir="$(cd "$artifact_dir" 2>/dev/null && pwd -P)" || return 1
  [[ "$resolved_dir" == "$artifact_dir" ]] || return 1
  path_is_within "$resolved_dir" "$repo_root"
}

# staging paths (<artifact>.partial/final/finalization-failure.$$) are
# predictable (pid + stable suffix) and their redirects must never follow a
# planted symlink: validate parent, leaf charset and non-symlink existence
# BEFORE the write, mirroring sidecar_file_is_safe
artifact_stage_is_safe() { # $1 = staging path under $artifact_dir
  local path="$1" parent leaf
  [[ -n "$path" ]] || return 1
  parent="$(dirname "$path")"
  leaf="${path##*/}"
  [[ "$parent" == "$artifact_dir" && "$leaf" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  artifact_dir_is_safe || return 1
  [[ ! -e "$path" && ! -L "$path" ]] || [[ -f "$path" && ! -L "$path" ]]
}


timestamp="$(date -u +%Y%m%d-%H%M%S)"
if [[ -z "$artifact_arg" ]]; then
  artifact_arg="$repo_root/.omx/artifacts/claude-${slug}-${timestamp}-$$.md"
elif [[ "$artifact_arg" != /* ]]; then
  artifact_arg="$repo_root/$artifact_arg"
fi
artifact="$(resolve_future_file "$artifact_arg")" || die "unsafe or unresolvable artifact path: $artifact_arg" 64
[[ "$artifact" == *.md ]] || die "artifact path must end in .md" 64
path_is_within "$artifact" "$repo_root" || die "artifact must remain inside repository worktree: $artifact" 64
artifact_rel="${artifact#"$repo_root"/}"
if [[ "$artifact_rel" == "$artifact" || ! "$artifact_rel" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  die "artifact path components must use literal-safe characters" 64
fi
IFS='/' read -r -a artifact_components <<<"$artifact_rel"
for artifact_component in "${artifact_components[@]}"; do
  [[ "$artifact_component" =~ ^[A-Za-z0-9._-]+$ && "$artifact_component" != "." && "$artifact_component" != ".." ]] || die "artifact path components must use literal-safe characters" 64
done
for blocked_root in "$git_dir" "$git_common_dir" "$skill_dir" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "${CODEX_HOME:-$HOME/.codex}" "$HOME/.codex" "$HOME/.claude"; do
  if [[ -d "$blocked_root" ]]; then
    blocked_root="$(cd "$blocked_root" 2>/dev/null && pwd -P)" || continue
    path_is_within "$artifact" "$blocked_root" && die "artifact path is inside a protected directory: $blocked_root" 64
  fi
done

artifact_dir="$(dirname "$artifact")"
mkdir -p "$artifact_dir" || die "unable to create artifact directory: $artifact_dir" 73
artifact_dir="$(cd "$artifact_dir" && pwd -P)" || die "unable to resolve artifact directory" 73
artifact="$artifact_dir/$(basename "$artifact")"
sidecar_dir="${artifact%.md}.d"
[[ ! -e "$artifact" && ! -L "$artifact" ]] || die "artifact already exists; refusing to overwrite: $artifact" 73
[[ ! -e "$sidecar_dir" && ! -L "$sidecar_dir" ]] || die "artifact sidecar already exists; refusing to mix runs: $sidecar_dir" 73

prompt_file="$sidecar_dir/prompt.txt"
raw_stdout="$sidecar_dir/stdout.json"
raw_stderr="$sidecar_dir/stderr.log"
execution_file="$sidecar_dir/execution.json"
process_log="$sidecar_dir/process-tree.log"
before_state="$sidecar_dir/git-before.json"
after_state="$sidecar_dir/git-after.json"
before_status="$sidecar_dir/git-before.status"
after_status="$sidecar_dir/git-after.status"
sandbox_profile="$sidecar_dir/sandbox.sb"
debug_output="$sidecar_dir/debug.log"
tracking_errors="$sidecar_dir/process-tracking-errors.log"
debug_temp=""
prompt_temp=""
raw_stdout_temp=""
raw_stderr_temp=""
phase="preflight"
finalized=false
review_pid=""
monitor_pid=""
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
started_epoch_ms="$(date +%s)000"
secret_detected=false
secret_scan_failed=false
secret_sources_json='[]'
secret_rule_ids_json='[]'
secret_rule_activation_count=0
caller_metadata_scanned=false
preflight_probe_pid=""
tool_usage_json='{}'
tool_usage_source="unavailable"
process_tracking_degraded=false
process_log_removal_reported=false
captured_outputs_published=false
prompt_publication_allowed=false
# authoritative in-memory copy of the tracked process tree: the file is
# best-effort evidence (a swapped/truncated/removed log must not influence
# kill decisions — sampled pids and releases come from this variable)
tracked_pids_memory=""

epoch_ms() {
  if [[ -n "$perl_bin" && -x "$perl_bin" ]] && "$perl_bin" -MTime::HiRes=time -e 'exit 0' >/dev/null 2>&1; then
    "$perl_bin" -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
  else
    printf '%s000\n' "$(date +%s)"
  fi
}

cleanup_staging_files() {
  local path
  for path in \
    "${artifact:-}.partial.$$" \
    "${artifact:-}.final.$$" \
    "${artifact:-}.finalization-failure.$$" \
    "${execution_file:-}.recovery.$$" \
    "${raw_stdout_temp:-}" \
    "${raw_stderr_temp:-}" \
    "${prompt_temp:-}" \
    "${debug_temp:-}"
  do
    [[ -n "$path" && -f "$path" ]] || continue
    # a swapped SIDE CAR DIRECTORY could resolve a predictable staging name
    # outside the repository: revalidate each wrapper-owned target against
    # its own path policy before unlinking (the capture temps live under the
    # runner-owned captures dir, which no swap can redirect)
    if [[ "$path" == "${artifact:-}."* ]]; then
      artifact_stage_is_safe "$path" || continue
    elif [[ "$path" == "${execution_file:-}."* ]]; then
      sidecar_file_is_safe "$path" || continue
    fi
    /bin/unlink "$path" 2>/dev/null || true
  done
  [[ -n "${captures_dir:-}" && -d "$captures_dir" ]] && /bin/rm -rf "$captures_dir" 2>/dev/null || true
  [[ -n "${provider_tmp:-}" && -d "$provider_tmp" ]] && /bin/rm -rf "$provider_tmp" 2>/dev/null || true

  if [[ -n "${sidecar_dir:-}" ]] && sidecar_dir_is_safe; then
    for path in "${execution_file:-}.tmp" "${execution_file:-}.running.$$"; do
      sidecar_file_is_safe "$path" && [[ -f "$path" ]] && /bin/unlink "$path" 2>/dev/null || true
    done
    for path in "$sidecar_dir"/*.capture.tmp."$$"; do
      sidecar_file_is_safe "$path" && [[ -f "$path" ]] && /bin/unlink "$path" 2>/dev/null || true
    done
  fi
}

stop_preflight_probe() {
  if [[ -n "$preflight_probe_pid" ]]; then
    kill "$preflight_probe_pid" 2>/dev/null || true
    wait "$preflight_probe_pid" 2>/dev/null || true
    preflight_probe_pid=""
  fi
}

artifact_path_is_safe() {
  local resolved_parent
  [[ -f "$artifact" && ! -L "$artifact" ]] || return 1
  resolved_parent="$(cd "$(dirname "$artifact")" 2>/dev/null && pwd -P)" || return 1
  [[ "$resolved_parent" == "$artifact_dir" ]] || return 1
  path_is_within "$artifact" "$repo_root"
}

sidecar_dir_is_safe() {
  local resolved_dir
  [[ -d "$sidecar_dir" && ! -L "$sidecar_dir" ]] || return 1
  resolved_dir="$(cd "$sidecar_dir" 2>/dev/null && pwd -P)" || return 1
  [[ "$resolved_dir" == "$sidecar_dir" ]] || return 1
  [[ "$(dirname "$resolved_dir")" == "$artifact_dir" ]] || return 1
  path_is_within "$resolved_dir" "$repo_root"
}

sidecar_file_is_safe() {
  local path="$1" parent leaf
  parent="$(dirname "$path")"
  leaf="$(basename "$path")"
  [[ "$parent" == "$sidecar_dir" && "$leaf" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  sidecar_dir_is_safe || return 1
  [[ ! -e "$path" && ! -L "$path" ]] || [[ -f "$path" && ! -L "$path" ]]
}

publish_artifact_file() {
  local source="$1"
  artifact_path_is_safe || return 1
  mv "$source" "$artifact" || return 1
  artifact_path_is_safe
}

record_tracking_error() {
  process_tracking_degraded=true
  sidecar_file_is_safe "$tracking_errors" || return 0
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >>"$tracking_errors" 2>/dev/null || true
}

emit_process_filter_warning() {
  [[ "$repo_process_filters_detected" == true ]] || return 0
  printf '> [!WARNING]\n> Git process filters are configured for this run\x27s effective config (origin: %s). The runner\x27s own snapshot calls could not neutralize them; treat the configuring scope as untrusted.\n\n' "$repo_process_filters_origin"
}

write_preflight_terminal_evidence() {
  local terminal_status="$1" reason="$2" signal_name="$3" exit_code="$4"
  local finished_at finished_epoch_ms duration_ms execution_temp artifact_temp published_task published_scope sidecar_safe=false execution_published=false artifact_published=false
  stop_preflight_probe
  if [[ "$caller_metadata_scanned" == false ]]; then
    published_task='[REDACTED: caller metadata not yet scanned]'
    published_scope='[REDACTED: caller metadata not yet scanned]'
  elif [[ "$secret_scan_failed" == true ]]; then
    published_task='[REDACTED: caller metadata scan failed]'
    published_scope='[REDACTED: caller metadata scan failed]'
  elif [[ "$secret_detected" == true ]]; then
    # distinguish provider-derived detections (provider-host, claude-version)
    # from genuine caller-input secrets so operators do not rewrite clean
    # task text that never contained a secret
    case " ${secret_sources_json}" in
      *'"provider-host"'*|*'"claude-version"'*)
        published_task='[REDACTED: sensitive provider metadata]'
        published_scope='[REDACTED: sensitive provider metadata]'
        ;;
      *)
        published_task='[REDACTED: sensitive caller metadata]'
        published_scope='[REDACTED: sensitive caller metadata]'
        ;;
    esac
  else
    published_task="$original_task"
    published_scope="$scope"
  fi
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  finished_epoch_ms="$(epoch_ms 2>/dev/null || printf '%s' "$started_epoch_ms")"
  duration_ms=$((finished_epoch_ms - started_epoch_ms))
  execution_temp="$execution_file.tmp"
  artifact_temp="$artifact.final.$$"
  artifact_stage_is_safe "$artifact_temp" || artifact_temp=""
  if sidecar_dir_is_safe; then
    sidecar_safe=true
  fi
  if [[ "$sidecar_safe" == true && -n "$jq_bin" && -x "$jq_bin" ]] && sidecar_file_is_safe "$execution_temp" && "$jq_bin" -n \
    --arg runner_version "$runner_version" \
    --arg status "$terminal_status" \
    --arg failure_reason "$reason" \
    --arg phase "preflight" \
    --arg started_at "$started_at" \
    --arg finished_at "$finished_at" \
    --arg termination_signal "$signal_name" \
    --arg task "$published_task" \
    --arg scope "$published_scope" \
    --arg artifact "$artifact" \
    --argjson started_at_epoch_ms "$started_epoch_ms" \
    --argjson finished_at_epoch_ms "$finished_epoch_ms" \
    --argjson duration_ms "$duration_ms" \
    --argjson exit_code "$exit_code" \
    --argjson secret_detected "$secret_detected" \
    --argjson secret_scan_failed "$secret_scan_failed" \
    --argjson secret_sources "$secret_sources_json" \
    --argjson secret_rule_ids "$secret_rule_ids_json" \
    --argjson secret_rule_activation_count "$secret_rule_activation_count" \
    '{runner_version:$runner_version,status:$status,failure_reason:$failure_reason,phase:$phase,started_at:$started_at,finished_at:$finished_at,started_at_epoch_ms:$started_at_epoch_ms,finished_at_epoch_ms:$finished_at_epoch_ms,duration_ms:$duration_ms,duration_precision:"milliseconds",exit_code:$exit_code,runner_exit_code:$exit_code,timed_out:false,termination_signal:(if $termination_signal == "" then null else $termination_signal end),task:$task,scope:$scope,artifact:$artifact,review_pid:null,secret_scan:{detected:$secret_detected,scan_failed:$secret_scan_failed,sources:$secret_sources,rule_ids:$secret_rule_ids,match_count:$secret_rule_activation_count},resources:{sampled_pids:[],remaining_pids:[],identity_mismatch_pids:[]}}' >"$execution_temp" && sidecar_file_is_safe "$execution_file" && mv "$execution_temp" "$execution_file" && sidecar_file_is_safe "$execution_file" && [[ -f "$execution_file" ]]; then
    execution_published=true
  elif [[ "$sidecar_safe" == true ]] && sidecar_file_is_safe "$execution_temp"; then
    printf '{"runner_version":"%s","status":"%s","failure_reason":"%s","phase":"preflight","exit_code":%s,"runner_exit_code":%s,"timed_out":false,"review_pid":null,"secret_scan":{"detected":false,"scan_failed":false,"sources":[],"rule_ids":[],"match_count":0},"resources":{"sampled_pids":[],"remaining_pids":[],"identity_mismatch_pids":[]}}\n' \
      "$runner_version" "$terminal_status" "$reason" "$exit_code" "$exit_code" >"$execution_temp" && sidecar_file_is_safe "$execution_file" && mv "$execution_temp" "$execution_file" && sidecar_file_is_safe "$execution_file" && [[ -f "$execution_file" ]] && execution_published=true
  fi
  [[ -n "$artifact_temp" ]] && {
    printf '# Claude Review: %s\n\n' "$slug"
    printf '> Status: `%s`\n\n' "$terminal_status"
    printf '## Failure\n\n- Phase: `preflight`\n- Reason: `%s`\n- Signal: `%s`\n- Exit code: `%s`\n\n' "$reason" "${signal_name:-none}" "$exit_code"
    printf '## Review Scope\n\n```text\n%s\n```\n\n' "$published_scope"
    emit_process_filter_warning
    printf 'Execution details: `%s`\n' "$execution_file"
  } >"$artifact_temp" && publish_artifact_file "$artifact_temp" && artifact_published=true
  if [[ "$artifact_published" == false && "$execution_published" == true && -n "$jq_bin" && -x "$jq_bin" ]] && sidecar_file_is_safe "$execution_file" && sidecar_file_is_safe "$execution_temp"; then
    "$jq_bin" --arg original_reason "$reason" '.failure_reason="artifact_write_failure" | .runner_exit_code=74 | .preflight_failure_reason=$original_reason' "$execution_file" >"$execution_temp" && sidecar_file_is_safe "$execution_file" && mv "$execution_temp" "$execution_file" && sidecar_file_is_safe "$execution_file" && [[ -f "$execution_file" ]] || execution_published=false
  fi
  if [[ "$sidecar_safe" == true ]]; then
    sidecar_file_is_safe "$raw_stdout" && printf '%s\n' '[no Claude stdout was published during preflight]' >"$raw_stdout" || sidecar_safe=false
    sidecar_file_is_safe "$raw_stderr" && printf '%s\n' '[no Claude stderr was published during preflight]' >"$raw_stderr" || sidecar_safe=false
    if [[ ! -f "$prompt_file" ]]; then
      sidecar_file_is_safe "$prompt_file" && printf '%s\n' '[no Claude prompt was published during preflight]' >"$prompt_file" || sidecar_safe=false
    fi
  fi
  if [[ "$artifact_published" == true && "$execution_published" == true && "$sidecar_safe" == true ]]; then
    finalized=true
    return 0
  fi
  return 1
}

handle_preflight_signal() {
  local signal_name="$1" exit_code="$2"
  trap '' INT TERM HUP
  write_preflight_terminal_evidence interrupted external_signal "$signal_name" "$exit_code" || exit 74
  exit "$exit_code"
}

fail_preflight() {
  local reason="$1" exit_code="$2"
  trap '' INT TERM HUP
  write_preflight_terminal_evidence failed "$reason" "" "$exit_code" || exit 74
  printf 'ask-claude review: %s\n' "$reason" >&2
  exit "$exit_code"
}

# signal/EXIT handlers must exist before the on-disk sidecar/artifact
# creation: an early TERM with no handler would leak the sidecar directory
# (the documented retry then fails with "refusing to mix runs" at this path)
trap cleanup_staging_files EXIT
trap 'handle_preflight_signal INT 130' INT
trap 'handle_preflight_signal TERM 143' TERM
trap 'handle_preflight_signal HUP 129' HUP
mkdir "$sidecar_dir" || die "unable to create unique artifact sidecar directory: $sidecar_dir" 73
chmod 700 "$sidecar_dir" 2>/dev/null || true
sidecar_dir="$(cd "$sidecar_dir" && pwd -P)" || die "unable to resolve artifact sidecar directory" 73
# the reservation redirect is a wrapper-owned artifact write like any other:
# revalidate the predictable leaf against the stage policy before opening it
artifact_stage_is_safe "$artifact" || die "unsafe artifact path: $artifact" 73
# a reservation failure must not leave the evidence-free sidecar behind (the
# documented retry would die at "refusing to mix runs" with no diagnostic)
reserve_artifact() {
  {
    printf '# Claude Review: %s\n\n' "$slug"
    printf '> Status: RUNNING. Artifact reserved before runtime dependency checks.\n'
  } >"$artifact"
}
if ! reserve_artifact; then
  # a failed open/write can leave an empty or partial reservation file that
  # would block the documented retry at the same path
  artifact_stage_is_safe "$artifact" && /bin/unlink "$artifact" 2>/dev/null || true
  rmdir "$sidecar_dir" 2>/dev/null || true
  die "unable to reserve artifact" 73
fi
sidecar_dir_is_safe || fail_preflight sidecar_path_unsafe 74
sidecar_file_is_safe "$raw_stdout" && : >"$raw_stdout" || fail_preflight sidecar_path_unsafe 74
sidecar_file_is_safe "$raw_stderr" && : >"$raw_stderr" || fail_preflight sidecar_path_unsafe 74
sidecar_file_is_safe "$process_log" && : >"$process_log" || fail_preflight sidecar_path_unsafe 74
chmod 600 "$raw_stdout" "$raw_stderr" "$process_log" 2>/dev/null || true
[[ -n "$claude_bin" && -x "$claude_bin" ]] || fail_preflight dependency_claude_missing 69
[[ -n "$jq_bin" && -x "$jq_bin" ]] || fail_preflight dependency_jq_missing 69
"$jq_bin" -n 'null' >/dev/null 2>&1 || fail_preflight dependency_jq_unusable 69
[[ -n "$perl_bin" && -x "$perl_bin" ]] || fail_preflight dependency_perl_missing 69
"$perl_bin" -MTime::HiRes=time -e 'exit 0' >/dev/null 2>&1 || fail_preflight dependency_time_hires_missing 69
[[ -n "$grep_bin" && -x "$grep_bin" ]] || fail_preflight dependency_grep_missing 69
printf 'probe\n' | "$grep_bin" -q probe 2>/dev/null || fail_preflight dependency_grep_unusable 69
[[ -n "$ps_bin" && -x "$ps_bin" ]] || fail_preflight dependency_ps_missing 69
"$ps_bin" -p $$ -o pid= >/dev/null 2>&1 || fail_preflight dependency_ps_unusable 69
ps_probe_output="$("$ps_bin" -p $$ -o ppid=,pgid=,lstart=,comm= 2>/dev/null)" || fail_preflight dependency_ps_unusable 69
[[ -n "${ps_probe_output//[[:space:]]/}" ]] || fail_preflight dependency_ps_unusable 69
[[ -n "$pgrep_bin" && -x "$pgrep_bin" ]] || fail_preflight dependency_pgrep_missing 69
sleep 1 &
preflight_probe_pid=$!
pgrep_probe_pid="$preflight_probe_pid"
pgrep_probe_output="$("$pgrep_bin" -P $$ 2>/dev/null)"
pgrep_probe_status=$?
stop_preflight_probe
pgrep_probe_found=false
while IFS= read -r pgrep_probe_line; do
  [[ "$pgrep_probe_line" =~ ^[[:space:]]*${pgrep_probe_pid}[[:space:]]*$ ]] && pgrep_probe_found=true
done <<<"$pgrep_probe_output"
[[ "$pgrep_probe_status" -eq 0 && "$pgrep_probe_found" == true ]] || fail_preflight dependency_pgrep_unusable 69
[[ -n "$mktemp_bin" && -x "$mktemp_bin" ]] || fail_preflight dependency_mktemp_missing 69
[[ -n "$hash_bin" && -x "$hash_bin" ]] || fail_preflight dependency_hash_missing 69
[[ "$hash_mode" == "shasum" || "$hash_mode" == "sha256sum" ]] || fail_preflight dependency_hash_mode_unsupported 69

started_epoch_ms="$(epoch_ms)" || fail_preflight clock_read_failure 70
# keep the ISO timestamp and the epoch pair on the SAME instant (the kimi
# sibling keeps them adjacent too): duration_ms is finished-started over the
# epoch pair, so started_at must not predate the epoch reset above
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# a planted FIFO/symlink at a capture path must fail preflight before any
# byte is written through it (the outer timeout only covers the provider)
capture_is_regular() { [[ -f "$1" && ! -L "$1" ]]; }
# provider captures live in a dedicated runner-owned directory under a
# per-UID shared root: the fixed name must not be a cross-UID squatting
# target (a root created by another user on a shared TMPDIR would otherwise
# permanently fail this user, and vice versa). EVERY run's profile
# write-denies the root (RUNNER_ROOT, appended last), so a concurrent run's
# provider cannot reach this run's captures either
shared_root="$tmp_dir/ask-claude-shared-$(id -u)"
[[ -L "$shared_root" ]] && fail_preflight captures_dir_creation_failure 73
mkdir -p "$shared_root" || fail_preflight captures_dir_creation_failure 73
# a pre-existing root owned by another user would let a squatter substitute
# the capture tree; tightening the mode fails with EPERM in that case and
# succeeds (0700) for anything we own
chmod 700 "$shared_root" 2>/dev/null || fail_preflight captures_dir_creation_failure 73
runner_root="$(cd "$shared_root" && pwd -P)" || fail_preflight captures_dir_creation_failure 73
captures_dir="$("$mktemp_bin" -d "$runner_root/captures.XXXXXX")" || fail_preflight captures_dir_creation_failure 73
chmod 700 "$captures_dir" 2>/dev/null || true
provider_tmp="$("$mktemp_bin" -d "$tmp_dir/ask-claude-provider.XXXXXX")" || fail_preflight provider_temp_creation_failure 73
# runner-owned tracked-tree union (provider-write-denied): kill decisions and
# evidence read from here, never from the provider-visible evidence log
tracked_union_file="$captures_dir/tracked-union.log"
: >"$tracked_union_file" 2>/dev/null || fail_preflight captures_dir_creation_failure 73
prompt_temp="$("$mktemp_bin" "$captures_dir/ask-claude-prompt.XXXXXX")" || fail_preflight prompt_temp_creation_failure 73
raw_stdout_temp="$("$mktemp_bin" "$captures_dir/ask-claude-stdout.XXXXXX")" || fail_preflight stdout_temp_creation_failure 73
raw_stderr_temp="$("$mktemp_bin" "$captures_dir/ask-claude-stderr.XXXXXX")" || fail_preflight stderr_temp_creation_failure 73
for capture in "$prompt_temp" "$raw_stdout_temp" "$raw_stderr_temp"; do
  capture_is_regular "$capture" || fail_preflight capture_temp_unusable 73
done

secret_rules=(
  'authorization_bearer|Authorization[[:space:]]*:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._~+/-]{12,}'
  'credential_assignment|(api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password)['\''"]?[[:space:]]*[:=][[:space:]]*['\''"]?[A-Za-z0-9._~+/-]{8,}'
  'anthropic_key|(^|[^[:alnum:]_])sk-ant-[A-Za-z0-9_-]{8,}'
  'github_token|ghp_[A-Za-z0-9]{12,}|github_pat_[A-Za-z0-9_]{12,}'
  'aws_access_key|AKIA[A-Z0-9]{16}'
  'gitlab_token|glpat-[A-Za-z0-9_-]{16,}'
  'slack_token|xox[baprs]-[A-Za-z0-9-]{10,}'
  'sk_token|(^|[^[:alnum:]_])sk-[A-Za-z0-9_-]{20,}'
  'generic_secret|(secret|token)['\''"]?[[:space:]]*[:=][[:space:]]*['\''"]?[A-Za-z0-9._~+/-]{16,}'
  'private_key|-----BEGIN ([A-Z ]+ )?PRIVATE KEY-----'
)

# exact-string scan needles: the configured provider base URL carries its
# credential in userinfo/query, shapes the ERE rules cannot match; its literal
# reappearance in provider text must block publication like a rule hit
secret_needles=()
# arm the exact-string needle only when the base URL carries a credential
# (userinfo, or a credential-shaped query): a plain credential-free endpoint
# echoed by the provider must not fail the run through the redaction ladder
_cred_query_re='[?&](api[_-]?key|key|token)='
if [[ -n "${ANTHROPIC_BASE_URL:-}" && ( "${ANTHROPIC_BASE_URL}" == *://*@* || "${ANTHROPIC_BASE_URL}" =~ $_cred_query_re ) ]]; then
  secret_needles+=("$ANTHROPIC_BASE_URL")
fi

append_secret_source() {
  secret_sources_json="$("$jq_bin" -cn --argjson current "$secret_sources_json" --arg source "$1" '$current + [$source] | unique')"
}

append_secret_rule() {
  secret_rule_ids_json="$("$jq_bin" -cn --argjson current "$secret_rule_ids_json" --arg rule "$1" '$current + [$rule] | unique')"
  secret_rule_activation_count=$((secret_rule_activation_count + 1))
}

scan_sensitive_text() {
  local value="$1" entry rule pattern scan_code found=false needle
  [[ -n "$value" ]] || return 1
  for needle in "${secret_needles[@]+"${secret_needles[@]}"}"; do
    LC_ALL=C "$grep_bin" -aFq -- "$needle" <<<"$value"
    scan_code=$?
    if [[ "$scan_code" -eq 0 ]]; then
      found=true
      append_secret_rule provider_base_url
    elif [[ "$scan_code" -gt 1 ]]; then
      [[ "$found" == true ]] && return 3
      return 2
    fi
  done
  for entry in "${secret_rules[@]}"; do
    rule="${entry%%|*}"
    pattern="${entry#*|}"
    LC_ALL=C "$grep_bin" -aEiq -- "$pattern" <<<"$value"
    scan_code=$?
    if [[ "$scan_code" -eq 0 ]]; then
      found=true
      append_secret_rule "$rule"
    elif [[ "$scan_code" -gt 1 ]]; then
      [[ "$found" == true ]] && return 3
      return 2
    fi
  done
  [[ "$found" == true ]] && return 0
  return 1
}

scan_sensitive_file() {
  local path="$1" entry rule pattern scan_code found=false needle
  [[ -s "$path" ]] || return 1
  for needle in "${secret_needles[@]+"${secret_needles[@]}"}"; do
    LC_ALL=C "$grep_bin" -aFq -- "$needle" "$path"
    scan_code=$?
    if [[ "$scan_code" -eq 0 ]]; then
      found=true
      append_secret_rule provider_base_url
    elif [[ "$scan_code" -gt 1 ]]; then
      [[ "$found" == true ]] && return 3
      return 2
    fi
  done
  for entry in "${secret_rules[@]}"; do
    rule="${entry%%|*}"
    pattern="${entry#*|}"
    LC_ALL=C "$grep_bin" -aEiq -- "$pattern" "$path"
    scan_code=$?
    if [[ "$scan_code" -eq 0 ]]; then
      found=true
      append_secret_rule "$rule"
    elif [[ "$scan_code" -gt 1 ]]; then
      [[ "$found" == true ]] && return 3
      return 2
    fi
  done
  [[ "$found" == true ]] && return 0
  return 1
}

scan_caller_metadata() {
  local label="$1" value="$2" scan_code
  scan_sensitive_text "$value"
  scan_code=$?
  if [[ "$scan_code" -eq 0 || "$scan_code" -eq 3 ]]; then
    secret_detected=true
    append_secret_source "$label"
  fi
  if [[ "$scan_code" -gt 1 ]]; then
    secret_scan_failed=true
    append_secret_source "$label-scan-error"
  fi
}

scan_caller_metadata task "$original_task"
scan_caller_metadata scope "$scope"
caller_metadata_scanned=true

capture_is_regular "$prompt_temp" || fail_preflight prompt_temp_unusable 73
cat >"$prompt_temp" <<EOF
Act as a strict senior code reviewer. Complete this review request: $original_task

Review this exact scope in the current repository: $scope

Inspect the requested diff and relevant source, tests, configuration, migrations, logs, and call sites yourself. Run git diff and other read-only inspection commands as needed. Do not ask clarifying questions; when evidence is missing, state the caveat and continue.

Keep this review strictly read-only. Do not edit, create, delete, rename, commit, push, install packages, change configuration, or alter the working tree. The operating-system sandbox is the enforcement boundary; this instruction is an additional behavioral constraint.

Check correctness, regressions, security and authorization, tenant isolation, data integrity, transaction and concurrency behavior, state transitions, idempotency, API compatibility, failure paths, boundary conditions, test adequacy, and project conventions. Report only evidence-backed, actionable defects. Use repository-relative file paths and line numbers whenever available.

Return the requested structured result with:
- verdict: PASS, NEEDS_ATTENTION, or BLOCKED
- findings ordered by severity, each with severity, file and line when known, issue, and recommendation
- caveats
- next_steps

Review scope: $scope
EOF
[[ "$?" -eq 0 && -s "$prompt_temp" ]] || fail_preflight prompt_temp_unusable 73
if [[ "$no_tools" == true ]]; then
  # --no-tools removes every tool, so the reviewer cannot inspect the scope by
  # itself; without this clause the schema-validating classifier would happily
  # accept a vacuous or fabricated verdict as a completed review
  capture_is_regular "$prompt_temp" || fail_preflight prompt_temp_unusable 73
  {
    printf '\nTool use is disabled for this run: you cannot read files, run git, or inspect the repository. If the requested scope material is not fully contained in this prompt, return verdict BLOCKED with a caveat stating that no repository content was available to review. Do not fabricate findings about code you cannot see.\n'
  } >>"$prompt_temp" || fail_preflight prompt_temp_unusable 73
fi
[[ -f "$prompt_temp" && ! -L "$prompt_temp" ]] || fail_preflight prompt_temp_unusable 73
scan_sensitive_file "$prompt_temp"
prompt_scan_code=$?
if [[ "$prompt_scan_code" -eq 0 || "$prompt_scan_code" -eq 3 ]]; then
  secret_detected=true
  append_secret_source prompt
fi
if [[ "$prompt_scan_code" -gt 1 ]]; then
  secret_scan_failed=true
  append_secret_source prompt-scan-error
fi

if [[ "$secret_detected" == true || "$secret_scan_failed" == true ]]; then
  original_task='[REDACTED: sensitive caller metadata]'
  scope='[REDACTED: sensitive caller metadata]'
  sidecar_file_is_safe "$prompt_file" || fail_preflight sidecar_path_unsafe 74
  printf '%s\n' '[REDACTED: review prompt withheld by sensitive-input policy]' >"$prompt_file"
  chmod 600 "$prompt_file" 2>/dev/null || true
  if [[ "$secret_scan_failed" == true ]]; then
    fail_preflight sensitive_input_scan_failure 78
  else
    fail_preflight sensitive_input_detected 78
  fi
fi
[[ -f "$prompt_temp" && ! -L "$prompt_temp" ]] || fail_preflight prompt_temp_unusable 73
sidecar_file_is_safe "$prompt_file" || fail_preflight sidecar_path_unsafe 74
cp "$prompt_temp" "$prompt_file" || fail_preflight artifact_write_failure 74
chmod 600 "$prompt_file" 2>/dev/null || true

artifact_class="explicit-repository-evidence"
case "$artifact" in
  "$repo_root"/.omx/artifacts/*) artifact_class="runtime-artifact" ;;
esac

provider_host="not-exposed"
if [[ -n "${ANTHROPIC_BASE_URL:-}" ]]; then
  provider_host="${ANTHROPIC_BASE_URL#*://}"
  # strip the LONGEST prefix ending at @: userinfo may itself contain @-separated
  # segments, and the shortest-prefix form would leave credential residue
  provider_host="${provider_host##*@}"
  # a credential may ride after the host in a query/fragment
  provider_host="${provider_host%%[?#]*}"
  provider_host="${provider_host%%/*}"
  # a bracketed IPv6 literal contains colons: strip to the closing bracket
  # instead of cutting at the first colon
  if [[ "$provider_host" == \[* ]]; then
    provider_host="${provider_host%%]*}"
    provider_host="${provider_host#\[}"
  else
    provider_host="${provider_host%%:*}"
  fi
  [[ -n "$provider_host" ]] || provider_host="not-exposed"
  # the derived host is provider-derived published text: scan it like every
  # other pre-publication surface (a gateway credential riding in the
  # hostname must quarantine the run, not pass silently)
  scan_caller_metadata provider-host "$provider_host"
fi

claude_version="$("$timeout_bin" -k 5s 30 "$claude_bin" --version 2>&1 | head -n 1 || true)"
claude_version="${claude_version:-unavailable}"
# the version output folds in stderr (auth/provider errors) — scan it like
# every other pre-publication text
scan_caller_metadata claude-version "$claude_version"
if [[ "$secret_detected" == true || "$secret_scan_failed" == true ]]; then
  if [[ "$secret_scan_failed" == true ]]; then
    fail_preflight sensitive_input_scan_failure 78
  fi
  fail_preflight sensitive_input_detected 78
fi

hash_file() {
  local input="$1" digest
  if [[ "$hash_mode" == "shasum" ]]; then
    digest="$("$hash_bin" -a 256 "$input" 2>/dev/null | awk 'NR == 1 {print $1}')" || return 1
  else
    digest="$("$hash_bin" "$input" 2>/dev/null | awk 'NR == 1 {print $1}')" || return 1
  fi
  [[ "$digest" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  printf '%s\n' "$digest"
}

git_excludes=()
case "$artifact" in
  "$repo_root"/*)
    sidecar_rel="${sidecar_dir#"$repo_root"/}"
    git_excludes+=(":(exclude,literal)$artifact_rel" ":(exclude,glob)$sidecar_rel/**")
    ;;
esac

capture_git_state() {
  local output_json="$1" status_output="$2" head index_fingerprint status_fingerprint worktree_fingerprint staged_fingerprint
  local index_snapshot="$sidecar_dir/index.capture.tmp.$$" worktree_snapshot="$sidecar_dir/worktree.capture.tmp.$$" staged_snapshot="$sidecar_dir/staged.capture.tmp.$$"
  sidecar_dir_is_safe || return 1
  sidecar_file_is_safe "$output_json" && sidecar_file_is_safe "$status_output" && sidecar_file_is_safe "$index_snapshot" && sidecar_file_is_safe "$worktree_snapshot" && sidecar_file_is_safe "$staged_snapshot" || return 1
  # snap_cfg/git_neutralize are provided by the parent (computed once, before
  # the first capture): the HEAD probe here distinguishes the legitimate
  # unborn-HEAD outcome (exit 1 via --verify -q) from real failures — a
  # fabricated sentinel would forge the mutation evidence
  head_out="$(snap_cfg rev-parse --verify -q HEAD)"; head_status=$?
  case "$head_status" in
    0) head="$head_out" ;;
    1) head="unborn" ;;
    *) return 1 ;;
  esac
  snap_git() {
    "$timeout_bin" -k 5s 300 "$git_bin" "${git_neutralize[@]}" -C "$repo_root" "$@" 2>/dev/null
  }
  snap_git status --porcelain=v1 --untracked-files=all -- . "${git_excludes[@]}" >"$status_output" || return 1
  snap_git ls-files --stage -- . "${git_excludes[@]}" >"$index_snapshot" || return 1
  snap_git diff --binary --no-ext-diff --no-textconv -- . "${git_excludes[@]}" >"$worktree_snapshot" || return 1
  snap_git diff --cached --binary --no-ext-diff --no-textconv -- . "${git_excludes[@]}" >"$staged_snapshot" || return 1
  index_fingerprint="$(hash_file "$index_snapshot")" || return 1
  status_fingerprint="$(hash_file "$status_output")" || return 1
  worktree_fingerprint="$(hash_file "$worktree_snapshot")" || return 1
  staged_fingerprint="$(hash_file "$staged_snapshot")" || return 1
  for capture_path in "$index_snapshot" "$worktree_snapshot" "$staged_snapshot"; do
    /bin/unlink "$capture_path" 2>/dev/null || true
  done
  # write the sidecar evidence copy AND emit the same JSON on stdout: the
  # caller keeps the stdout copy in memory so the mutation delta never
  # re-reads the on-disk file (a swapped evidence file could forge
  # "no mutation")
  "$jq_bin" -n \
    --arg head "$head" \
    --arg index_fingerprint "$index_fingerprint" \
    --arg status_fingerprint "$status_fingerprint" \
    --arg worktree_fingerprint "$worktree_fingerprint" \
    --arg staged_fingerprint "$staged_fingerprint" \
    '{head:$head,index_fingerprint:$index_fingerprint,status_fingerprint:$status_fingerprint,worktree_fingerprint:$worktree_fingerprint,staged_fingerprint:$staged_fingerprint}' >"$output_json" || return 1
  cat "$output_json"
}

write_partial_artifact() {
  local temp_artifact="$artifact.partial.$$"
  artifact_stage_is_safe "$temp_artifact" || return 1
  {
    printf '# Claude Review: %s\n\n' "$slug"
    printf '> Status: RUNNING. This file was created before Claude started. Intermediate silence is not completion evidence.\n\n'
    printf '## Review Scope\n\n```text\n%s\n```\n\n' "$scope"
    printf '## Execution\n\n- Started: `%s`\n' "$started_at"
    printf -- '- Timeout: `%s`\n' "$timeout_value"
    printf -- '- Working directory: `%s`\n' "$repo_root"
    printf -- '- Raw stdout: `%s`\n' "$raw_stdout"
    printf -- '- Raw stderr: `%s`\n' "$raw_stderr"
    printf -- '- Execution record: `%s`\n' "$execution_file"
  } >"$temp_artifact" || return 1
  publish_artifact_file "$temp_artifact"
}

write_partial_artifact || fail_preflight artifact_write_failure 74
# repo-config-driven execution neutralization + process-filter detection for
# the runner's own snapshot git calls — computed in the PARENT so the
# disclosure state is authoritative (capture_git_state runs in a command
# substitution and its assignments would be trapped there)
snap_cfg() { "$timeout_bin" -k 5s 30 "$git_bin" -C "$repo_root" "$@" 2>/dev/null; }
git_neutralize=(-c core.fsmonitor=false -c core.hooksPath=/dev/null -c diff.external=)
filter_keys="$(snap_cfg config --name-only --get-regexp '^filter\.[^ ]*\.(clean|smudge)$')"; fk_status=$?
# exit 1 = no match (legitimate); a failed read must fail the parent closed
# rather than silently skipping the neutralization
[[ "$fk_status" -le 1 ]] || fail_preflight mutation_snapshot_failure 70
while IFS= read -r filter_key; do
  [[ -n "$filter_key" ]] || continue
  # clean/smudge keys are per-driver (filter.<driver>.clean|smudge):
  # override each configured driver with `cat` (identity conversion)
  git_neutralize+=(-c "$filter_key=cat")
done <<<"$filter_keys"
repo_process_filters_detected=false
repo_process_filters_origin=""
_pf_info="$(snap_cfg config --show-origin --get-regexp '^filter\.[^ ]*\.process$')"; pf_status=$?
[[ "$pf_status" -le 1 ]] || fail_preflight mutation_snapshot_failure 70
if [[ -n "$_pf_info" ]]; then
  repo_process_filters_detected=true
  repo_process_filters_origin="$(printf '%s\n' "$_pf_info" | cut -f1 | sort -u | tr '\n' ' ')"
fi
# in-memory copy of the before state: the mutation delta is computed from
# this, never from the on-disk sidecar files a provider could swap
before_json_mem="$(capture_git_state "$before_state" "$before_status")" || fail_preflight mutation_snapshot_failure 70

isolation_mode="prompt-only"
isolation_description="sandbox-exec unavailable; prompt constraint plus mutation detection only"
sandbox_runner=()
if [[ "$(uname -s)" == "Darwin" ]] && sandbox_exec_bin="$(command -v sandbox-exec 2>/dev/null)"; then
  sidecar_file_is_safe "$sandbox_profile" || fail_preflight sidecar_path_unsafe 74
rp_path() { /usr/bin/perl -MCwd=realpath -e 'print(realpath($ARGV[0]) // $ARGV[0])' "$1" 2>/dev/null || printf '%s' "$1"; }

# canonicalization availability: without a usable perl the realpath step
# falls back to raw spellings, which SBPL treats as inert — surface it
# instead of silently reverting to the pre-fix behaviour
canon_unavailable=0
[[ -x /usr/bin/perl ]] || canon_unavailable=1
canon_note=""
[[ "$canon_unavailable" == 1 ]] && canon_note="; WARNING path canonicalization unavailable (perl missing): symlink-sensitive denies may be inert"
  claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  codex_home="${CODEX_HOME:-$HOME/.codex}"
  # P3-4 hardening (mirrors the kimi sibling): the credential boundary must
  # cover the literal $HOME/.codex even when CODEX_HOME points elsewhere, so a
  # non-Codex host exporting CODEX_HOME for its own tooling cannot move the
  # deny boundary away from the default Codex credential store.
  codex_default_dir=""
  if [[ -d "$HOME/.codex" && "$HOME/.codex" != "${CODEX_HOME:-$HOME/.codex}" ]]; then
    codex_default_dir="$(cd "$HOME/.codex" 2>/dev/null && pwd -P)" || codex_default_dir=""
  fi
  # SBPL matches kernel-resolved paths — canonicalize both homes like every
  # other profile param (an uncanonicalized literal is silently inert).
  # Fail-safe: if cd fails on an existing path, keep the literal value
  # instead of assigning an empty string (which would root-anchor the
  # CLAUDE_* allow set at /).
  if [[ -d "$claude_home" ]]; then
    _ch="$(cd "$claude_home" 2>/dev/null && pwd -P)" && [[ -n "$_ch" ]] && claude_home="$_ch"
  fi
  if [[ -d "$codex_home" ]]; then
    _cx="$(cd "$codex_home" 2>/dev/null && pwd -P)" && [[ -n "$_cx" ]] && codex_home="$_cx"
  fi
  # same hardening for the code-bearing default Claude store: a host exporting
  # CLAUDE_CONFIG_DIR for an isolated agent home must not move the write
  # boundary away from ~/.claude (skills/plugins/hooks/settings/CLAUDE.md).
  # Computed AFTER claude_home canonicalization and compared against the
  # canonical value: an aliased spelling (trailing slash, `./` segments, a
  # symlinked store) must count as "same store" or the appended deny — the
  # LAST write rule in the profile — would void the enumerated runtime
  # re-allow set (the 1.5.9 claude-cannot-write-its-state failure class).
  claude_default_dir=""
  _claude_default="$(cd "$HOME/.claude" 2>/dev/null && pwd -P)" || _claude_default=""
  # skip when the active store NESTS inside the default tree: the appended
  # deny is the last write rule and would otherwise cover the active store's
  # enumerated runtime re-allows too (the 1.5.9 cannot-write-state class)
  if [[ -n "$_claude_default" && "$_claude_default" != "$claude_home" ]] && ! path_is_within "$claude_home" "$_claude_default"; then
    claude_default_dir="$_claude_default"
  fi
  # runner-owned write-canary dir (unpredictable path, denied in the profile)
  canary_dir="$("$mktemp_bin" -d "$tmp_dir/ask-claude-canary.XXXXXX" 2>/dev/null)" || canary_dir=""
  if [[ -z "$canary_dir" ]]; then
    canary_dir="$tmp_dir/ask-claude-canary-$$.$RANDOM"
    mkdir "$canary_dir" 2>/dev/null || canary_dir=""
  fi
  cat >"$sandbox_profile" <<'SANDBOX'
(version 1)
(deny default)
(allow process*)
(allow file-read*)
(deny file-read* (subpath (param "SSH_DIR")))
(deny file-read* (subpath (param "AWS_DIR")))
(deny file-read* (subpath (param "GNUPG_DIR")))
(deny file-read* (subpath (param "GH_DIR")))
(deny file-read* (subpath (param "KUBE_DIR")))
(deny file-read* (subpath (param "DOCKER_DIR")))
(deny file-read* (subpath (param "AZURE_DIR")))
(deny file-read* (subpath (param "GCLOUD_DIR")))
(deny file-read* (subpath (param "CODEX_HOME")))
(deny file-read* (literal (param "GIT_CREDENTIALS")))
(deny file-read* (literal (param "NETRC")))
(deny file-read* (literal (param "NPMRC")))
(deny file-read* (literal (param "PYPRC")))
(deny file-read* (literal (param "YARNRC_FILE")))
(deny file-read* (literal (param "GIT_XDG_CREDENTIALS")))
(deny file-read* (subpath (param "TERRAFORM_DIR")))
(deny file-read* (subpath (param "PIP_CONFIG_DIR")))
(deny file-read* (literal (param "PIP_LEGACY_FILE")))
(deny file-read* (subpath (param "BUNDLE_DIR")))
(deny file-read* (literal (param "GEM_CREDENTIALS_FILE")))
(deny file-read* (literal (param "M2_SETTINGS_FILE")))
(deny file-read* (literal (param "GRADLE_PROPERTIES_FILE")))
(deny file-read* (literal (param "CARGO_CREDENTIALS_FILE")))
(deny file-read* (literal (param "COMPOSER_AUTH_FILE")))
(allow file-read* (subpath (param "SKILL_DIR")))
(allow file-write* (subpath (param "TMP_DIR")))
(allow file-write* (subpath "/tmp"))
(allow file-write* (subpath "/private/tmp"))
(allow file-write* (literal "/dev/null"))
; CLAUDE_HOME is deny-by-default; the runtime write set and the
; code-bearing config re-denies are ordered at the END of this profile
; (after the target denies) so last-match-wins resolves correctly even for
; a home-rooted toplevel
(deny file-write* (subpath (param "CLAUDE_HOME")))
(allow network*)
(allow sysctl-read)
(deny file-write* (subpath (param "WORKSPACE")))
(deny file-write* (subpath (param "GIT_DIR")))
(deny file-write* (subpath (param "GIT_COMMON_DIR")))
(deny file-write* (subpath (param "SKILL_DIR")))
(deny file-write* (subpath (param "CANARY_DIR")))
; the CLAUDE_* runtime write set is re-asserted AFTER the target denies:
; with a home-rooted toplevel (--repo $HOME) the WORKSPACE deny would
; otherwise outrank it and claude could not write its own runtime state.
; NOTE: no blanket CLAUDE_HOME allow — the enumeration below IS the
; boundary (a blanket allow would subsume it and re-open the whole tree)
(allow file-write* (subpath (param "CLAUDE_PROJECTS_DIR")))
(allow file-write* (subpath (param "CLAUDE_TODOS_DIR")))
(allow file-write* (subpath (param "CLAUDE_SESSIONS_DIR")))
(allow file-write* (subpath (param "CLAUDE_SESSION_DATA_DIR")))
(allow file-write* (subpath (param "CLAUDE_SHELL_SNAPSHOTS_DIR")))
(allow file-write* (subpath (param "CLAUDE_METRICS_DIR")))
(allow file-write* (subpath (param "CLAUDE_TELEMETRY_DIR")))
(allow file-write* (literal (param "CLAUDE_HISTORY_FILE")))
(allow file-write* (literal (param "CLAUDE_COST_LOG")))
; live-verified claude state written in the last hour (2026-09-22): audit
; logs, command log, session env, task/backup state, MCP caches
(allow file-write* (subpath (param "CLAUDE_SECURITY_DIR")))
(allow file-write* (subpath (param "CLAUDE_SESSION_ENV_DIR")))
(allow file-write* (subpath (param "CLAUDE_TASKS_DIR")))
(allow file-write* (subpath (param "CLAUDE_BACKUPS_DIR")))
(allow file-write* (literal (param "CLAUDE_BASH_LOG")))
(allow file-write* (literal (param "CLAUDE_MCP_HEALTH")))
(allow file-write* (literal (param "CLAUDE_MCP_AUTH")))
(allow file-write* (literal (param "CLAUDE_LAST_CLEANUP")))
; ...but the code-bearing config surfaces are re-denied LAST
(deny file-write* (subpath (param "CLAUDE_SKILLS_DIR")))
(deny file-write* (subpath (param "CLAUDE_PLUGINS_DIR")))
(deny file-write* (subpath (param "CLAUDE_HOOKS_DIR")))
(deny file-write* (subpath (param "CLAUDE_COMMANDS_DIR")))
(deny file-write* (subpath (param "CLAUDE_AGENTS_DIR")))
(deny file-write* (literal (param "CLAUDE_SETTINGS")))
(deny file-write* (literal (param "CLAUDE_SETTINGS_LOCAL")))
(deny file-write* (literal (param "CLAUDE_MD")))
SANDBOX
  # appended AFTER the broad read allow and every later re-allow: appended
  # rules win under SBPL last-match-wins, so the relocated-store deny cannot
  # be voided by any earlier or later read rule in the static profile
  if [[ -n "$codex_default_dir" ]]; then
    printf '(deny file-read* (subpath (param "CODEX_DEFAULT_DIR")))\n' >>"$sandbox_profile"
  fi
  if [[ -n "$claude_default_dir" ]]; then
    printf '(deny file-write* (subpath (param "CLAUDE_DEFAULT_DIR")))\n' >>"$sandbox_profile"
  fi
  # appended last so the CAPTURES_DIR deny outranks the TMP_DIR write allow
  # under last-match-wins: the sandboxed provider must never reach the
  # runner-owned capture files by path (a forged capture would otherwise be
  # read back as genuine review evidence)
  printf '(allow file-write* (subpath (param "PROVIDER_TMP")))\n' >>"$sandbox_profile"
  printf '(deny file-write* (subpath (param "CAPTURES_DIR")))\n' >>"$sandbox_profile"
  # appended LAST: a concurrent run's provider cannot write this run's
  # captures through the broad TMP_DIR/tmp allows either
  printf '(deny file-write* (subpath (param "RUNNER_ROOT")))\n' >>"$sandbox_profile"
  sandbox_runner=("$sandbox_exec_bin"
    -D "WORKSPACE=$repo_root"
    -D "RUNNER_ROOT=$runner_root"
    -D "GIT_DIR=$git_dir"
    -D "GIT_COMMON_DIR=$git_common_dir"
    -D "SKILL_DIR=$skill_dir"
    -D "TMP_DIR=$tmp_dir"
    -D "PROVIDER_TMP=$provider_tmp"
    -D "CAPTURES_DIR=$captures_dir"
    -D "CANARY_DIR=$canary_dir"
    -D "CLAUDE_HOME=$claude_home"
    -D "CLAUDE_DEFAULT_DIR=${claude_default_dir:-/nonexistent-claude-default}"
    -D "CODEX_HOME=$codex_home"
    -D "CODEX_DEFAULT_DIR=${codex_default_dir:-/nonexistent-codex-default}"
    -D "CLAUDE_PROJECTS_DIR=$claude_home/projects"
    -D "CLAUDE_TODOS_DIR=$claude_home/todos"
    -D "CLAUDE_SESSIONS_DIR=$claude_home/sessions"
    -D "CLAUDE_SESSION_DATA_DIR=$claude_home/session-data"
    -D "CLAUDE_SHELL_SNAPSHOTS_DIR=$claude_home/shell-snapshots"
    -D "CLAUDE_METRICS_DIR=$claude_home/metrics"
    -D "CLAUDE_TELEMETRY_DIR=$claude_home/telemetry"
    -D "CLAUDE_HISTORY_FILE=$claude_home/history.jsonl"
    -D "CLAUDE_COST_LOG=$claude_home/cost-tracker.log"
    -D "CLAUDE_SECURITY_DIR=$claude_home/security"
    -D "CLAUDE_SESSION_ENV_DIR=$claude_home/session-env"
    -D "CLAUDE_TASKS_DIR=$claude_home/tasks"
    -D "CLAUDE_BACKUPS_DIR=$claude_home/backups"
    -D "CLAUDE_BASH_LOG=$claude_home/bash-commands.log"
    -D "CLAUDE_MCP_HEALTH=$claude_home/mcp-health-cache.json"
    -D "CLAUDE_MCP_AUTH=$claude_home/mcp-needs-auth-cache.json"
    -D "CLAUDE_LAST_CLEANUP=$claude_home/.last-cleanup"
    -D "CLAUDE_SKILLS_DIR=$claude_home/skills"
    -D "CLAUDE_PLUGINS_DIR=$claude_home/plugins"
    -D "CLAUDE_HOOKS_DIR=$claude_home/hooks"
    -D "CLAUDE_COMMANDS_DIR=$claude_home/commands"
    -D "CLAUDE_AGENTS_DIR=$claude_home/agents"
    -D "CLAUDE_SETTINGS=$claude_home/settings.json"
    -D "CLAUDE_SETTINGS_LOCAL=$claude_home/settings.local.json"
    -D "CLAUDE_MD=$claude_home/CLAUDE.md"
    -D "SSH_DIR=$(rp_path "$HOME/.ssh")"
    -D "AWS_DIR=$(rp_path "$HOME/.aws")"
    -D "GNUPG_DIR=$(rp_path "$HOME/.gnupg")"
    -D "GH_DIR=$(rp_path "$HOME/.config/gh")"
    -D "KUBE_DIR=$(rp_path "$HOME/.kube")"
    -D "DOCKER_DIR=$(rp_path "$HOME/.docker")"
    -D "AZURE_DIR=$(rp_path "$HOME/.azure")"
    -D "GCLOUD_DIR=$(rp_path "$HOME/.config/gcloud")"
    -D "GIT_CREDENTIALS=$(rp_path "$HOME/.git-credentials")"
    -D "NETRC=$(rp_path "$HOME/.netrc")"
    -D "NPMRC=$(rp_path "$HOME/.npmrc")"
    -D "PYPRC=$(rp_path "$HOME/.pypirc")"
    -D "YARNRC_FILE=$(rp_path "$HOME/.yarnrc.yml")"
    -D "GIT_XDG_CREDENTIALS=$(rp_path "$HOME/.config/git/credentials")"
    -D "TERRAFORM_DIR=$(rp_path "$HOME/.terraform.d")"
    -D "PIP_CONFIG_DIR=$(rp_path "$HOME/.config/pip")"
    -D "PIP_LEGACY_FILE=$(rp_path "$HOME/.pip/pip.conf")"
    -D "BUNDLE_DIR=$(rp_path "$HOME/.bundle")"
    -D "GEM_CREDENTIALS_FILE=$(rp_path "$HOME/.gem/credentials")"
    -D "M2_SETTINGS_FILE=$(rp_path "$HOME/.m2/settings.xml")"
    -D "GRADLE_PROPERTIES_FILE=$(rp_path "$HOME/.gradle/gradle.properties")"
    -D "CARGO_CREDENTIALS_FILE=$(rp_path "$HOME/.cargo/credentials.toml")"
    -D "COMPOSER_AUTH_FILE=$(rp_path "$HOME/.composer/auth.json")"
    -f "$sandbox_profile")
  # enforcement canary: an applied sandbox is only trustworthy if its denies
  # actually fire — probe an apply plus a write attempt against a runner-owned
  # CANARY_DIR (mktemp -d under TMP_DIR, added to the profile's write-denies);
  # the reviewed repo is never touched and read-only targets cannot skip the
  # probe. Any failure degrades honestly to prompt-only.
  canary_ok=true
  "${sandbox_runner[@]}" /usr/bin/true 2>/dev/null || canary_ok=false
  if [[ "$canary_ok" == true ]]; then
    if [[ -z "$canary_dir" ]]; then
      canary_ok=false
    else
      if "${sandbox_runner[@]}" /bin/sh -c 'echo x >> "$1"' _ "$canary_dir/probe" >/dev/null 2>&1; then
        canary_ok=false
      fi
      /bin/rm -rf "$canary_dir" 2>/dev/null || true
    fi
  fi
  # liveness canary: claude must still start under the profile (a profile
  # that denies state claude needs would otherwise surface as an opaque
  # provider error while the ISO reports macos-sandbox)
  canary_fail=""
  if [[ "$canary_ok" == true ]]; then
    if ! "$timeout_bin" -k 5s 30 "${sandbox_runner[@]}" "$claude_bin" --version >/dev/null 2>&1; then
      canary_ok=false
      canary_fail="claude_liveness"
    fi
  fi
  if [[ "$canary_ok" == true ]]; then
    isolation_mode="macos-sandbox"
    isolation_description="repository, Git, and skill writes denied (probed via a runner-owned write canary covering the same SBPL mechanism; repo/git/skill targets inferred); selected credential reads denied; not a general secrets or network boundary${canon_note}"
  else
    sandbox_runner=()
    [[ -n "$canary_dir" ]] && /bin/rm -rf "$canary_dir" 2>/dev/null || true
    isolation_mode="prompt-only"
    if [[ "$canary_fail" == "claude_liveness" ]]; then
      isolation_description="claude could not start under the sandbox profile (failed canary: claude_liveness); review is prompt-only isolated with mutation detection only"
    else
      isolation_description="sandbox-exec unavailable or boundaries not enforcing on this host (failed canary: sandbox_apply_or_write_deny); review is prompt-only isolated with mutation detection only"
    fi
  fi
else
  sidecar_file_is_safe "$sandbox_profile" || fail_preflight sidecar_path_unsafe 74
  printf '%s\n' 'sandbox-exec unavailable; review is prompt-only isolated' >"$sandbox_profile"
fi

claude_args=(
  -p
  --dangerously-skip-permissions
  --no-chrome
  --disallowedTools "Edit,Write,NotebookEdit,WebSearch,WebFetch"
  --output-format json
  --json-schema "$review_schema"
)
if [[ "$no_tools" == true ]]; then
  # untrusted/archived repositories: no tools at all, so nothing the reviewed
  # repo ships can steer an auto-approved capability (SKILL: untrusted-repo mode)
  claude_args+=(--tools "")
fi
if [[ "$debug_mode" == false ]]; then
  claude_args+=(--no-session-persistence)
else
  # the debug trace is provider-authored output (written by claude through
  # --debug-file), so it stays in the provider-writable tmp; the runner scans
  # it before publication like every other provider capture
  debug_temp="$("$mktemp_bin" "$provider_tmp/ask-claude-debug.XXXXXX")" || fail_preflight debug_temp_creation_failure 73
  claude_args+=(--debug-file "$debug_temp")
fi
if [[ "$safe_mode" == true ]]; then
  claude_args+=(--safe-mode)
fi
if [[ -n "$fallback_model" ]]; then
  claude_args+=(--fallback-model "$fallback_model")
fi

command_display=("$timeout_bin" -k 5s "$timeout_value" ${sandbox_runner[@]+"${sandbox_runner[@]}"} env)
if [[ "$watchdog_enabled" == true ]]; then
  command_display+=(CLAUDE_CODE_RETRY_WATCHDOG=1)
else
  command_display+=(-u CLAUDE_CODE_RETRY_WATCHDOG)
fi
command_display+=("TMPDIR=$provider_tmp")
command_display+=("$claude_bin" "${claude_args[@]}" '< prompt.txt')
sidecar_file_is_safe "$sidecar_dir/command.txt" || fail_preflight sidecar_path_unsafe 74
printf '%q ' "${command_display[@]}" >"$sidecar_dir/command.txt" || fail_preflight artifact_write_failure 74
printf '\n' >>"$sidecar_dir/command.txt" || fail_preflight artifact_write_failure 74

sidecar_file_is_safe "$execution_file" || fail_preflight sidecar_path_unsafe 74
"$jq_bin" -n \
  --arg runner_version "$runner_version" \
  --arg started_at "$started_at" \
  --arg timeout "$timeout_value" \
  --arg task "$original_task" \
  --arg scope "$scope" \
  --arg artifact "$artifact" \
  --arg artifact_class "$artifact_class" \
  --arg provider_host "$provider_host" \
  --arg claude_version "$claude_version" \
  --arg isolation_mode "$isolation_mode" \
  --arg isolation_description "$isolation_description" \
  --arg fallback_model "$fallback_model" \
  --arg phase "preflight" \
  --argjson started_at_epoch_ms "$started_epoch_ms" \
  --argjson wrapper_pid "$$" \
  --argjson watchdog_enabled "$watchdog_enabled" \
  --argjson safe_mode "$safe_mode" \
  --argjson no_tools "$no_tools" \
  --argjson debug_mode "$debug_mode" \
  '{runner_version:$runner_version,status:"running",phase:$phase,started_at:$started_at,started_at_epoch_ms:$started_at_epoch_ms,duration_precision:"milliseconds",timeout:$timeout,task:$task,scope:$scope,artifact:$artifact,artifact_class:$artifact_class,provider_host:$provider_host,models:[],claude_version:$claude_version,wrapper_pid:$wrapper_pid,review_pid:null,watchdog_enabled:$watchdog_enabled,safe_mode:$safe_mode,no_tools:$no_tools,debug_mode:$debug_mode,fallback_model:$fallback_model,isolation:{mode:$isolation_mode,description:$isolation_description}}' >"$execution_file" || fail_preflight execution_record_write_failure 74

termination_signal=""
spawn_critical=false
pending_signal=""
pending_signal_code=""

process_identity() {
  local pid="$1" ps_output ps_status identity
  # identity fields must survive BOTH reparenting and process-group changes:
  # - a parent exit re-parents descendants to launchd, changing their ppid;
  # - GNU timeout setpgid(0,0)s itself into a fresh process group right after
  #   exec, so pgid captured at fork time goes stale within milliseconds.
  # lstart (spawn time) and comm survive both — a changed value means PID
  # reuse (matches the kimi sibling's documented rationale).
  ps_output="$("$ps_bin" -p "$pid" -o lstart=,comm= 2>/dev/null)"
  ps_status=$?
  # procps returns 1 for a process that exited after discovery; only >=2
  # establishes that the ps tool itself was unavailable or malformed.
  if [[ "$ps_status" -eq 1 ]]; then
    return 1
  elif [[ "$ps_status" -ne 0 ]]; then
    return 2
  fi
  identity="$(printf '%s\n' "$ps_output" | awk 'NF {$1=$1; print; exit}')"
  [[ -n "$identity" ]] || return 1
  printf '%s\n' "$identity"
}

record_tree() {
  local parent="$1" child children identity identity_status pgrep_status already_tracked=false
  kill -0 "$parent" 2>/dev/null || return 0
  if awk -F '\t' -v pid="$parent" '$1 == pid {found=1} END {exit !found}' <<<"$tracked_pids_memory" 2>/dev/null; then
    already_tracked=true
  fi
  identity="$(process_identity "$parent")"
  identity_status=$?
  if [[ -z "$identity" ]]; then
    # A sampled PID may exit between kill -0 and ps; only a first-sighting
    # ps execution failure proves that tracking was unavailable during execution.
    [[ "$already_tracked" == true || "$identity_status" -lt 2 ]] || record_tracking_error ps_identity_runtime_failure
    return 0
  fi
  if [[ "$already_tracked" == false ]]; then
    # the union file (provider-write-denied) is authoritative for decisions;
    # the in-repo log is published evidence only
    tracked_pids_memory+="${parent}"$'\t'"${identity}"$'\n'
    printf '%s\t%s\n' "$parent" "$identity" >>"$tracked_union_file" 2>/dev/null || true
    # existence-gated: a REMOVED log must not be silently recreated by this
    # append (that would hide the removal and drop pre-removal samples)
    if [[ -f "$process_log" ]] && sidecar_file_is_safe "$process_log"; then
      printf '%s\t%s\n' "$parent" "$identity" >>"$process_log" || true
    else
      process_tracking_degraded=true
      [[ "$process_log_removal_reported" == true ]] || {
        record_tracking_error process_log_path_unsafe
        process_log_removal_reported=true
      }
    fi
  fi
  children="$("$pgrep_bin" -P "$parent" 2>/dev/null)"
  pgrep_status=$?
  if [[ "$pgrep_status" -gt 1 ]]; then
    record_tracking_error pgrep_runtime_failure
    return 0
  fi
  while IFS= read -r child; do
    [[ -n "$child" ]] && record_tree "$child"
  done <<<"$children"
}

monitor_tree() {
  while kill -0 "$1" 2>/dev/null; do
    record_tree "$1"
    sleep 0.1
  done
  record_tree "$1"
}

stop_monitor() {
  if [[ -n "$monitor_pid" ]] && kill -0 "$monitor_pid" 2>/dev/null; then
    kill -TERM "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
  fi
  monitor_pid=""
}

# Merge sampled entries from the provider-write-denied union file into the
# in-memory tree. The monitor subshell appends there because its memory
# writes cannot reach the parent; this union is what makes monitor-discovered
# descendants visible to cleanup and evidence. Validates the union path
# before reading.
refresh_tracked_memory_from_log() {
  # the union file is the decision input: require a regular non-symlink file
  # inside the runner-owned captures dir before trusting it; a planted
  # FIFO/symlink/relocation degrades tracking instead of blocking or lying
  if ! [[ -f "$tracked_union_file" && ! -L "$tracked_union_file" ]] ||
     [[ "$(cd "$(dirname "$tracked_union_file")" 2>/dev/null && pwd -P)" != "$captures_dir" ]]; then
    record_tracking_error union_path_unsafe
    return 0
  fi
  while IFS=$'\t' read -r lpid lidentity; do
    [[ -n "$lpid" ]] || continue
    if ! awk -F '\t' -v pid="$lpid" '$1 == pid {found=1} END {exit !found}' <<<"$tracked_pids_memory" 2>/dev/null; then
      tracked_pids_memory+="${lpid}"$'\t'"${lidentity}"$'\n'
    fi
  done <"$tracked_union_file"
}

release_processes() {
  local include_review_pid="$1" pid expected_identity current_identity identity_status terminated_any=false
  # kill decisions run from the in-memory union (fed by the provider-write-
  # denied tracked-union file) with per-pid identity revalidation before any
  # signal. The in-repo evidence log is not consulted for decisions; issues
  # with it are reported as degradation instead.
  if ! sidecar_dir_is_safe || ! sidecar_file_is_safe "$process_log" || ! [[ -f "$process_log" ]]; then
    record_tracking_error process_log_path_unsafe
  fi
  refresh_tracked_memory_from_log
  while IFS=$'\t' read -r pid expected_identity; do
    [[ -n "$pid" ]] || continue
    if [[ "$include_review_pid" != true && "$pid" == "${review_pid:-}" ]]; then
      continue
    fi
    if kill -0 "$pid" 2>/dev/null; then
      current_identity="$(process_identity "$pid")"
      identity_status=$?
      if [[ -z "$current_identity" ]]; then
        [[ "$identity_status" -lt 2 ]] || record_tracking_error ps_identity_runtime_failure
        continue
      fi
      [[ -n "$expected_identity" && "$current_identity" == "$expected_identity" ]] || continue
      kill -TERM "$pid" 2>/dev/null || true
      terminated_any=true
    fi
  done < <(printf '%s' "$tracked_pids_memory" | awk -F '\t' '{lines[NR]=$0} END {for (i=NR; i>=1; i--) print lines[i]}')
  [[ "$terminated_any" == false ]] || sleep 0.2
  while IFS=$'\t' read -r pid expected_identity; do
    [[ -n "$pid" ]] || continue
    if [[ "$include_review_pid" != true && "$pid" == "${review_pid:-}" ]]; then
      continue
    fi
    current_identity="$(process_identity "$pid")"
    identity_status=$?
    if kill -0 "$pid" 2>/dev/null && [[ -z "$current_identity" ]]; then
      [[ "$identity_status" -lt 2 ]] || record_tracking_error ps_identity_runtime_failure
      continue
    fi
    if kill -0 "$pid" 2>/dev/null && [[ -n "$expected_identity" && "$current_identity" == "$expected_identity" ]]; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done < <(printf '%s' "$tracked_pids_memory" | awk -F '\t' '{lines[NR]=$0} END {for (i=NR; i>=1; i--) print lines[i]}')
}

release_tracked_processes() {
  release_processes false
}

release_signal_processes() {
  release_processes true
}

models_json='[]'
model_usage_json='{}'
usage_json='null'
permission_denials_json='[]'
structured_output_json='null'
claude_session_id=""
claude_duration_ms_json='null'
claude_duration_api_ms_json='null'
terminal_reason=""
status="failed"
failure_reason="unfinalized"
timed_out=false
cli_exit_code=70
runner_exit_code=70

publish_captured_outputs() {
  local label path scan_code
  # conservative failure: a swapped/unreadable target must leave the
  # secret-scan flags in the failed state, otherwise the finalize record would
  # publish provider-derived payloads that scanning never examined.
  # return 2 marks capture VALIDATION failure (distinguishable in the record
  # from a real publication write failure)
  if ! sidecar_file_is_safe "$raw_stdout" || ! sidecar_file_is_safe "$raw_stderr"; then
    secret_scan_failed=true
    append_secret_source "captured-output-scan-error"
    return 2
  fi
  if [[ "$debug_mode" == true ]] && ! sidecar_file_is_safe "$debug_output"; then
    secret_scan_failed=true
    append_secret_source "captured-output-scan-error"
    return 2
  fi
  # belt-and-braces: the capture temps live in provider-reachable locations,
  # but a swapped or non-regular capture must still fail the scan closed
  # instead of being copied or parsed by name (the debug trace is
  # provider-authored inside PROVIDER_TMP, so it is swap-prone by design)
  for capture in "$raw_stdout_temp" "$raw_stderr_temp" "$debug_temp"; do
    [[ -n "$capture" ]] || continue
    if ! [[ -f "$capture" && ! -L "$capture" ]]; then
      secret_scan_failed=true
      append_secret_source "captured-output-scan-error"
      return 2
    fi
  done
  for entry in "stdout:$raw_stdout_temp" "stderr:$raw_stderr_temp"; do
    label="${entry%%:*}"
    path="${entry#*:}"
    scan_sensitive_file "$path"
    scan_code=$?
    if [[ "$scan_code" -eq 0 || "$scan_code" -eq 3 ]]; then
      secret_detected=true
      append_secret_source "$label"
    fi
    if [[ "$scan_code" -gt 1 ]]; then
      secret_scan_failed=true
      append_secret_source "$label-scan-error"
    fi
  done
  if [[ -n "$debug_temp" && -f "$debug_temp" && ! -L "$debug_temp" ]]; then
    scan_sensitive_file "$debug_temp"
    scan_code=$?
    if [[ "$scan_code" -eq 0 || "$scan_code" -eq 3 ]]; then
      secret_detected=true
      append_secret_source debug
    fi
    if [[ "$scan_code" -gt 1 ]]; then
      secret_scan_failed=true
      append_secret_source debug-scan-error
    fi
  fi

  if [[ "$secret_detected" == true || "$secret_scan_failed" == true ]]; then
    printf '%s\n' '[REDACTED: raw stdout withheld by sensitive-output policy]' >"$raw_stdout" || return 1
    printf '%s\n' '[REDACTED: raw stderr withheld by sensitive-output policy]' >"$raw_stderr" || return 1
    [[ "$debug_mode" == false ]] || printf '%s\n' '[REDACTED: debug trace withheld by sensitive-output policy]' >"$debug_output" || return 1
  else
    cp "$raw_stdout_temp" "$raw_stdout" || return 1
    cp "$raw_stderr_temp" "$raw_stderr" || return 1
    if [[ -n "$debug_temp" && -f "$debug_temp" && ! -L "$debug_temp" ]]; then
      cp "$debug_temp" "$debug_output" || return 1
    fi
  fi
  chmod 600 "$raw_stdout" "$raw_stderr" 2>/dev/null || true
  [[ ! -f "$debug_output" ]] || chmod 600 "$debug_output" 2>/dev/null || true
  # only a validated, scanned pair may ever be read back into the artifact
  captured_outputs_published=true
}

extract_tool_usage() {
  local candidate="" debug_marker_count debug_record_count
  tool_usage_json='{}'
  tool_usage_source="unavailable"
  if [[ -s "$raw_stdout_temp" ]] && "$jq_bin" -e '.tool_usage | type == "object"' "$raw_stdout_temp" >/dev/null 2>&1; then
    candidate="$("$jq_bin" -c '
      (.tool_usage // {})
      | to_entries
      | map(select(.key | test("^[A-Za-z0-9_.-]+$"))
          | select(.value | type == "object")
          | {key:.key, value:{count:(.value.count // 0), failed:(.value.failed // 0)}})
      | from_entries
    ' "$raw_stdout_temp")"
    if [[ -n "$candidate" ]] && "$jq_bin" -e 'all(.[]; (.count | type == "number" and . >= 0 and . == floor) and (.failed | type == "number" and . >= 0 and . == floor))' <<<"$candidate" >/dev/null 2>&1; then
      tool_usage_json="$candidate"
      tool_usage_source="provider-json"
      return 0
    fi
  fi
  if [[ "$debug_mode" == true && -s "$debug_output" ]]; then
    candidate="$("$jq_bin" -Rsc '
      {
        marker_count: ([scan("tool_dispatch_end")] | length),
        # Claude Code 2.1.210 emits tool= before outcome=. A format change
        # intentionally produces a marker/record mismatch and fails closed.
        records: [scan("tool_dispatch_end[^\\r\\n]*tool=(?<tool>[A-Za-z0-9_.-]+)[^\\r\\n]*outcome=(?<outcome>[A-Za-z0-9_.-]+)") | {tool:.[0], outcome:.[1]}]
      }
    ' "$debug_output" 2>/dev/null || true)"
    if [[ -n "$candidate" ]] && "$jq_bin" -e '(.marker_count | type == "number") and (.records | type == "array")' <<<"$candidate" >/dev/null 2>&1; then
      debug_marker_count="$("$jq_bin" -r '.marker_count' <<<"$candidate")"
      debug_record_count="$("$jq_bin" -r '.records | length' <<<"$candidate")"
      if [[ "$debug_marker_count" -gt 0 && "$debug_record_count" -ne "$debug_marker_count" ]]; then
        tool_usage_source="debug-trace-parse-failed"
        return 2
      fi
      if [[ "$debug_record_count" -gt 0 ]]; then
        tool_usage_json="$("$jq_bin" -c '
          .records
          | group_by(.tool)
          | map({key:.[0].tool, value:{count:length, failed:(map(select(.outcome != "ok")) | length)}})
          | from_entries
        ' <<<"$candidate")"
      fi
    fi
    if [[ -n "$tool_usage_json" ]] && "$jq_bin" -e 'type == "object" and length > 0' <<<"$tool_usage_json" >/dev/null 2>&1; then
      tool_usage_source="debug-trace"
    fi
  fi
}

finalize() {
  [[ "$finalized" == false ]] || return 0
  # evidence publication is the point of no return: ignore further INT/TERM/
  # HUP (installed BEFORE finalized=true so a signal in between cannot re-enter
  # the handler and abandon an in-flight publication) — a late signal can
  # neither abort a half-published artifact nor overwrite the terminal exit
  # code after publication completed
  trap '' INT TERM HUP
  finalized=true
  phase="review"
  stop_monitor
  release_tracked_processes
  if ! sidecar_dir_is_safe; then
    status="failed"
    failure_reason="sidecar_path_unsafe"
    runner_exit_code=74
    write_finalization_failure_artifact || true
    return 0
  fi
  if ! sidecar_file_is_safe "$execution_file"; then
    status="failed"
    failure_reason="sidecar_path_unsafe"
    runner_exit_code=74
    write_finalization_failure_artifact || true
    return 0
  fi

  # A tracking-errors file that never existed is CLEAN (no errors recorded).
  # A file that existed at this read and is gone/unsafe at the second read is
  # a removal: the second site keeps this read's reasons and reports it.
  tracking_errors_seen=false
  if sidecar_file_is_safe "$tracking_errors" && [[ -f "$tracking_errors" ]]; then
    tracking_errors_seen=true
    process_tracking_reasons_json="$(awk -F '\t' 'NF >= 2 {print $2}' "$tracking_errors" 2>/dev/null | sort -u | "$jq_bin" -Rsc 'split("\n") | map(select(length > 0))')"
    if "$jq_bin" -e 'length > 0' <<<"$process_tracking_reasons_json" >/dev/null 2>&1; then
      process_tracking_degraded=true
    fi
  else
    process_tracking_reasons_json='[]'
  fi

  # publication-time prompt validation + re-scan (before publish so the
  # secret flags feed the same ladder as every other surface): a prompt.txt
  # swapped between launch and publication is detected here and fails the
  # run closed; write_final_artifact prints a placeholder instead
  prompt_publication_allowed=false
  if [[ -f "$prompt_file" && ! -L "$prompt_file" ]] && sidecar_file_is_safe "$prompt_file"; then
    scan_sensitive_file "$prompt_file"; prompt_rescan_code=$?
    if [[ "$prompt_rescan_code" -eq 0 || "$prompt_rescan_code" -eq 3 ]]; then
      secret_detected=true
      append_secret_source prompt-final
    elif [[ "$prompt_rescan_code" -gt 1 ]]; then
      secret_scan_failed=true
      append_secret_source prompt-final-scan-error
    else
      prompt_publication_allowed=true
    fi
    if [[ "$secret_detected" == true || "$secret_scan_failed" == true ]]; then
      # overwrite the quarantined bytes so an archived sidecar does not carry
      # the secret-shaped content the runner just withheld from the artifact
      sidecar_file_is_safe "$prompt_file" && printf '%s\n' '[REDACTED: review prompt withheld by sensitive-output policy]' >"$prompt_file"
    fi
  else
    # swapped/removed/unsafe prompt sidecar: an evidence-integrity failure
    # with its own reason (not a process-tracking degradation)
    prompt_path_unsafe=true
  fi

  publish_captured_outputs; publish_rc=$?
  if [[ "$prompt_path_unsafe" == true ]]; then
    status="failed"
    failure_reason="prompt_path_unsafe"
    runner_exit_code=74
  elif [[ "$publish_rc" -eq 2 ]]; then
    # capture validation failure: the temps were swapped/non-regular — the
    # artifact itself was never written through a bad path
    status="failed"
    failure_reason="capture_validation_failure"
    runner_exit_code=74
  elif [[ "$publish_rc" -ne 0 ]]; then
    status="failed"
    failure_reason="artifact_write_failure"
    runner_exit_code=74
  elif [[ "$secret_scan_failed" == true ]]; then
    status="failed"
    failure_reason="secret_scan_failure"
    runner_exit_code=78
  elif [[ "$secret_detected" == true && "$status" != "interrupted" ]]; then
    status="failed"
    failure_reason="sensitive_output_detected"
    runner_exit_code=78
  fi
  extract_tool_usage
  tool_usage_status=$?
  if [[ "$tool_usage_status" -eq 2 && "$status" == "completed" ]]; then
    status="failed"
    failure_reason="tool_usage_parse_failure"
    runner_exit_code=65
  elif [[ "$process_tracking_degraded" == true && "$status" == "completed" ]]; then
    status="failed"
    failure_reason="process_tracking_degraded"
    runner_exit_code=70
  fi
  if [[ "$secret_detected" == true || "$secret_scan_failed" == true ]]; then
    models_json='[]'
    model_usage_json='{}'
    usage_json='null'
    permission_denials_json='[]'
    structured_output_json='null'
    tool_usage_json='{}'
    tool_usage_source="unavailable"
    claude_session_id=""
    claude_duration_ms_json='null'
    claude_duration_api_ms_json='null'
    terminal_reason=""
  fi

  if ! after_json_mem="$(capture_git_state "$after_state" "$after_status")"; then
    # a valid placeholder keeps the final record's --argjson inputs total
    after_json_mem='{"error":"unable to capture post-review Git state"}'
    status="failed"
    failure_reason="mutation_snapshot_failure"
    runner_exit_code=70
  fi
  # mutation delta from the in-memory snapshots only: the on-disk
  # git-before/after.json files are published evidence, not decision inputs
  # a failed post-snapshot produces a non-comparable placeholder: only real
  # fingerprint differences may claim "working tree changed"
  changed_fields_json="$("$jq_bin" -n --argjson before "$before_json_mem" --argjson after "$after_json_mem" '["head","index_fingerprint","status_fingerprint","worktree_fingerprint","staged_fingerprint"] | map(select($after[.] != null and $before[.] != $after[.]))')"
  changed_fields_json="${changed_fields_json:-[]}"
  if [[ "$changed_fields_json" == "[]" ]]; then
    mutation_detected=false
  else
    mutation_detected=true
  fi

  if ! sidecar_dir_is_safe || ! sidecar_file_is_safe "$process_log" || ! [[ -f "$process_log" ]]; then
    # swapped/replaced/removed evidence log: contents are untrusted, so
    # report degradation; decisions still run from the in-memory union
    record_tracking_error process_log_path_unsafe
  else
    refresh_tracked_memory_from_log
  fi
  sampled_pids_json="$(printf '%s' "$tracked_pids_memory" | awk -F '\t' 'NF {print $1}' | sort -u | "$jq_bin" -Rsc 'split("\n") | map(select(length > 0) | tonumber)')"
  remaining_pids_json='[]'
  identity_mismatch_pids_json='[]'
  while IFS=$'\t' read -r tracked_pid expected_identity; do
    [[ -n "$tracked_pid" ]] || continue
    if kill -0 "$tracked_pid" 2>/dev/null; then
      current_identity="$(process_identity "$tracked_pid")"
      identity_status=$?
      if [[ -z "$current_identity" ]]; then
        [[ "$identity_status" -lt 2 ]] || record_tracking_error ps_identity_runtime_failure
        identity_mismatch_pids_json="$("$jq_bin" -cn --argjson current "$identity_mismatch_pids_json" --argjson pid "$tracked_pid" '$current + [$pid] | unique')"
      elif [[ -n "$expected_identity" && "$current_identity" == "$expected_identity" ]]; then
        remaining_pids_json="$("$jq_bin" -cn --argjson current "$remaining_pids_json" --argjson pid "$tracked_pid" '$current + [$pid] | unique')"
      else
        identity_mismatch_pids_json="$("$jq_bin" -cn --argjson current "$identity_mismatch_pids_json" --argjson pid "$tracked_pid" '$current + [$pid] | unique')"
      fi
    fi
  done <<<"$tracked_pids_memory"

  if sidecar_file_is_safe "$tracking_errors" && [[ -f "$tracking_errors" ]]; then
    process_tracking_reasons_json="$(awk -F '\t' 'NF >= 2 {print $2}' "$tracking_errors" 2>/dev/null | sort -u | "$jq_bin" -Rsc 'split("\n") | map(select(length > 0))')"
  elif [[ "$tracking_errors_seen" == true ]]; then
    # existed at the first read, gone now: removal must not un-report the
    # degradation the first read captured
    record_tracking_error tracking_errors_path_unsafe
    process_tracking_degraded=true
  elif [[ ! -e "$tracking_errors" && ! -L "$tracking_errors" && "$tracking_errors_seen" != true ]]; then
    # genuinely never existed (a dangling symlink is a REPLACEMENT, not
    # absence — it must fall through to the untrusted handling below)
    process_tracking_reasons_json='[]'
  else
    # removed after the first read, a dangling-symlink replacement, or an
    # otherwise unsafe path: report the cause instead of an empty list
    record_tracking_error tracking_errors_path_unsafe
    process_tracking_reasons_json='["tracking_errors_path_unsafe"]'
    process_tracking_degraded=true
  fi
  if "$jq_bin" -e 'length > 0' <<<"$process_tracking_reasons_json" >/dev/null 2>&1; then
    process_tracking_degraded=true
  fi
  # escalate on the in-memory flag, not the reasons list: every path that sets
  # the flag (recorded errors, a swapped/removed/dangling log) must turn a
  # completed run into a failure even if its evidence file was removed
  if [[ "$process_tracking_degraded" == true && "$status" == "completed" ]]; then
    status="failed"
    failure_reason="process_tracking_degraded"
    runner_exit_code=70
  fi

  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  finished_epoch_ms="$(epoch_ms)"
  duration_ms=$((finished_epoch_ms - started_epoch_ms))
  # in-memory snapshots are the decision source; the sidecar copies are
  # published evidence only (never re-read for the delta or the record)
  before_json="$before_json_mem"
  after_json="$after_json_mem"

  if sidecar_file_is_safe "$execution_file.tmp" && sidecar_file_is_safe "$execution_file" \
    && "$jq_bin" -n \
    --arg runner_version "$runner_version" \
    --arg status "$status" \
    --arg failure_reason "$failure_reason" \
    --arg phase "$phase" \
    --arg started_at "$started_at" \
    --arg finished_at "$finished_at" \
    --arg timeout "$timeout_value" \
    --arg termination_signal "$termination_signal" \
    --arg terminal_reason "$terminal_reason" \
    --arg claude_session_id "$claude_session_id" \
    --arg task "$original_task" \
    --arg scope "$scope" \
    --arg artifact "$artifact" \
    --arg artifact_class "$artifact_class" \
    --arg provider_host "$provider_host" \
    --arg claude_version "$claude_version" \
    --arg isolation_mode "$isolation_mode" \
    --arg isolation_description "$isolation_description" \
    --arg fallback_model "$fallback_model" \
    --arg tool_usage_source "$tool_usage_source" \
    --argjson duration_ms "$duration_ms" \
    --argjson started_at_epoch_ms "$started_epoch_ms" \
    --argjson finished_at_epoch_ms "$finished_epoch_ms" \
    --argjson wrapper_pid "$$" \
    --argjson review_pid "${review_pid:-null}" \
    --argjson exit_code "$cli_exit_code" \
    --argjson runner_exit_code "$runner_exit_code" \
    --argjson timed_out "$timed_out" \
    --argjson watchdog_enabled "$watchdog_enabled" \
    --argjson safe_mode "$safe_mode" \
    --argjson no_tools "$no_tools" \
    --argjson debug_mode "$debug_mode" \
    --argjson models "$models_json" \
    --argjson model_usage "$model_usage_json" \
    --argjson usage "$usage_json" \
    --argjson permission_denials "$permission_denials_json" \
    --argjson tool_usage "$tool_usage_json" \
    --argjson structured_output "$structured_output_json" \
    --argjson claude_duration_ms "$claude_duration_ms_json" \
    --argjson claude_duration_api_ms "$claude_duration_api_ms_json" \
    --argjson mutation_detected "$mutation_detected" \
    --argjson changed_fields "$changed_fields_json" \
    --argjson before "$before_json" \
    --argjson after "$after_json" \
    --argjson sampled_pids "$sampled_pids_json" \
    --argjson remaining_pids "$remaining_pids_json" \
    --argjson identity_mismatch_pids "$identity_mismatch_pids_json" \
    --argjson secret_detected "$secret_detected" \
    --argjson secret_scan_failed "$secret_scan_failed" \
    --argjson secret_sources "$secret_sources_json" \
    --argjson secret_rule_ids "$secret_rule_ids_json" \
    --argjson secret_rule_activation_count "$secret_rule_activation_count" \
    --argjson process_tracking_degraded "$process_tracking_degraded" \
    --argjson process_tracking_reasons "$process_tracking_reasons_json" \
    '{runner_version:$runner_version,status:$status,failure_reason:(if $failure_reason == "" then null else $failure_reason end),phase:$phase,started_at:$started_at,finished_at:$finished_at,started_at_epoch_ms:$started_at_epoch_ms,finished_at_epoch_ms:$finished_at_epoch_ms,duration_ms:$duration_ms,duration_precision:"milliseconds",timeout:$timeout,wrapper_pid:$wrapper_pid,review_pid:$review_pid,exit_code:$exit_code,runner_exit_code:$runner_exit_code,timed_out:$timed_out,termination_signal:(if $termination_signal == "" then null else $termination_signal end),terminal_reason:(if $terminal_reason == "" then null else $terminal_reason end),task:$task,scope:$scope,artifact:$artifact,artifact_class:$artifact_class,provider_host:$provider_host,models:$models,claude_version:$claude_version,claude:{session_id:(if $claude_session_id == "" then null else $claude_session_id end),duration_ms:$claude_duration_ms,duration_api_ms:$claude_duration_api_ms,usage:$usage,modelUsage:$model_usage,permission_denials:$permission_denials,structured_output:$structured_output},watchdog_enabled:$watchdog_enabled,safe_mode:$safe_mode,no_tools:$no_tools,debug_mode:$debug_mode,fallback_model:$fallback_model,tool_usage:{source:$tool_usage_source,tools:$tool_usage},isolation:{mode:$isolation_mode,description:$isolation_description},process_tracking:{degraded:$process_tracking_degraded,reasons:$process_tracking_reasons},secret_scan:{detected:$secret_detected,scan_failed:$secret_scan_failed,sources:$secret_sources,rule_ids:$secret_rule_ids,match_count:$secret_rule_activation_count},mutation:{detected:$mutation_detected,changed_fields:$changed_fields,before:$before,after:$after},resources:{sampled_pids:$sampled_pids,remaining_pids:$remaining_pids,identity_mismatch_pids:$identity_mismatch_pids}}' >"$execution_file.tmp" \
    && sidecar_file_is_safe "$execution_file.tmp" && sidecar_file_is_safe "$execution_file" \
    && mv "$execution_file.tmp" "$execution_file" && sidecar_file_is_safe "$execution_file" && [[ -f "$execution_file" ]]; then
    :
  else
    # guarded: a jq failure (bad --argjson input, ENOSPC) previously left the
    # redirect-created empty temp in place and the run still reported
    # completed/exit 0 with an empty sidecar — fail closed instead
    runner_exit_code=74
    if [[ "$status" == "completed" ]]; then
      status="failed"
      failure_reason="execution_record_write_failure"
    fi
    # republish a terminal record (printf fallback: jq itself just failed)
    # carrying the LIVE terminal state so a polling host never sees
    # status:"running" forever and the record never contradicts the artifact
    execution_recovery="$execution_file.recovery.$$"
    if sidecar_file_is_safe "$execution_file" && sidecar_file_is_safe "$execution_recovery" \
      && printf '{"runner_version":"%s","status":"%s","failure_reason":"%s","phase":"%s","exit_code":%s,"runner_exit_code":74,"timed_out":%s}\n' \
        "$runner_version" "$status" "${failure_reason:-execution_record_write_failure}" "$phase" "$cli_exit_code" "$timed_out" >"$execution_recovery" \
      && mv "$execution_recovery" "$execution_file"; then
      :
    fi
  fi

  if ! write_final_artifact; then
    status="failed"
    failure_reason="artifact_write_failure"
    runner_exit_code=74
    sidecar_file_is_safe "$execution_file.tmp" && sidecar_file_is_safe "$execution_file" \
    && "$jq_bin" '.status="failed" | .failure_reason="artifact_write_failure" | .runner_exit_code=74' "$execution_file" >"$execution_file.tmp" && sidecar_file_is_safe "$execution_file.tmp" && sidecar_file_is_safe "$execution_file" && mv "$execution_file.tmp" "$execution_file" && sidecar_file_is_safe "$execution_file" && [[ -f "$execution_file" ]]
    write_finalization_failure_artifact || true
  fi
}

write_final_artifact() {
  local temp_artifact="$artifact.final.$$" models_display tool_usage_display verdict raw_language mutation_detected_value
  artifact_stage_is_safe "$temp_artifact" || return 1
  # point-of-use revalidation: a replacement landing after publication must
  # not drive the verdict or be published as the review's raw output
  stdout_usable=false
  stderr_usable=false
  if [[ -f "$raw_stdout" && ! -L "$raw_stdout" ]] && sidecar_file_is_safe "$raw_stdout"; then
    stdout_usable=true
  fi
  if [[ -f "$raw_stderr" && ! -L "$raw_stderr" ]] && sidecar_file_is_safe "$raw_stderr"; then
    stderr_usable=true
  fi
  models_display="$("$jq_bin" -r '.models | if length == 0 then "not reported" else join(", ") end' "$execution_file")"
  tool_usage_display="$("$jq_bin" -c '.tool_usage' "$execution_file")"
  mutation_detected_value="$("$jq_bin" -r '.mutation.detected' "$execution_file")"
  verdict="unavailable"
  raw_language="text"
  # a rejected/unvalidated stdout.json must never drive the verdict line or
  # the raw sections (write_final_artifact runs after publish could refuse)
  if [[ "$captured_outputs_published" == true && "$stdout_usable" == true ]] && "$jq_bin" -e . "$raw_stdout" >/dev/null 2>&1; then
    verdict="$("$jq_bin" -r '.structured_output.verdict // "unavailable"' "$raw_stdout")"
    raw_language="json"
  fi
  {
    printf '# Claude Review: %s\n\n' "$slug"
    printf '> Status: `%s`\n\n' "$status"
    if [[ "$mutation_detected_value" == true ]]; then
      printf '> [!WARNING]\n> Working tree or repository state changed during the review window. This may be a concurrent user change; inspect Git evidence and do not attribute it to Claude automatically.\n\n'
    fi
    if [[ "$isolation_mode" != "macos-sandbox" ]]; then
      printf '> [!WARNING]\n> Raw captures and the prompt sidecar are not write-protected on this host (prompt-only isolation); the published review text is unauthenticated.\n\n'
    fi
    emit_process_filter_warning
    printf 'Execution details: `%s`\n' "$execution_file"
    if [[ "$secret_detected" == true || "$secret_scan_failed" == true ]]; then
      printf '> [!WARNING]\n> Raw provider output was withheld because sensitive-output scanning detected a secret pattern or could not complete safely.\n\n'
    fi
    printf '## Original Task\n\n```text\n%s\n```\n\n' "$original_task"
    printf '## Review Scope\n\n```text\n%s\n```\n\n' "$scope"
    printf '## Final Prompt\n\n```text\n'
    if [[ "$prompt_publication_allowed" == true ]] && [[ -f "$prompt_file" && ! -L "$prompt_file" ]] && sidecar_file_is_safe "$prompt_file"; then
      cat "$prompt_file"
    else
      printf '%s\n' '[REDACTED: prompt withheld by sensitive-output policy]'
    fi
    printf '```\n\n' 
    printf '## Execution\n\n'
    printf -- '- Artifact class: `%s`\n' "$artifact_class"
    printf -- '- Working directory: `%s`\n' "$repo_root"
    printf -- '- Claude CLI: `%s`\n' "$claude_version"
    printf -- '- Started: `%s`\n' "$started_at"
    printf -- '- Finished: `%s`\n' "$("$jq_bin" -r '.finished_at' "$execution_file")"
    printf -- '- Duration: `%s ms`\n' "$("$jq_bin" -r '.duration_ms' "$execution_file")"
    printf -- '- Timeout: `%s`\n' "$timeout_value"
    printf -- '- Exit code: `%s`\n' "$cli_exit_code"
    printf -- '- Runner exit code: `%s`\n' "$runner_exit_code"
    printf -- '- Timed out: `%s`\n' "$timed_out"
    printf -- '- Termination signal: `%s`\n' "${termination_signal:-none}"
    printf -- '- Terminal reason: `%s`\n' "${terminal_reason:-unavailable}"
    printf -- '- Provider host: `%s`\n' "$provider_host"
    printf -- '- Actual models: `%s`\n' "$models_display"
    printf -- '- Isolation: `%s`\n' "$isolation_description"
    printf -- '- Watchdog enabled: `%s`\n' "$watchdog_enabled"
    printf -- '- Safe mode: `%s`\n' "$safe_mode"
    printf -- '- Tools: `%s`\n' "$([[ "$no_tools" == true ]] && printf 'none (--no-tools)' || printf 'default')"
    printf -- '- Debug mode: `%s`\n' "$debug_mode"
    printf -- '- Fallback model: `%s`\n' "${fallback_model:-none}"
    printf -- '- Tool usage source: `%s`\n' "$tool_usage_source"
    printf -- '- Tool usage summary: `%s`\n\n' "$tool_usage_display"
    printf 'Exact redacted command is stored at `%s`. The review prompt was passed through stdin; no Git diff was piped to Claude.\n\n' "$sidecar_dir/command.txt"
    # SKILL contract: provider verdicts from runs that failed the completion
    # contract must never be presented as review results
    if [[ "$status" == "completed" && "$captured_outputs_published" == true ]]; then
      printf '## Parsed Review\n\n- Verdict: `%s`\n' "$verdict"
    else
      printf '## Parsed Review\n\n- Verdict: `unavailable` (run did not complete: %s)\n' "${failure_reason:-unknown}"
    fi
    if [[ -n "$failure_reason" ]]; then
      printf -- '- Failure reason: `%s`\n\n' "$failure_reason"
    else
      printf '%s\n\n' '- Failure reason: (none; review completed successfully)'
    fi
    if [[ "$status" == "completed" && "$captured_outputs_published" == true && "$stdout_usable" == true ]] && "$jq_bin" -e '.structured_output | type == "object"' "$raw_stdout" >/dev/null 2>&1; then
      printf '```json\n'
      "$jq_bin" '.structured_output' "$raw_stdout"
      printf '```\n\n'
    fi
    printf '## Mutation Check\n\n```json\n'
    "$jq_bin" '.mutation' "$execution_file"
    printf '```\n\n'
    printf 'Before and after status snapshots are stored in `%s` and `%s`.\n\n' "$before_status" "$after_status"
    printf '## Resource Check\n\n```json\n'
    "$jq_bin" '.resources' "$execution_file"
    printf '```\n\n'
    printf '## Raw Claude Output\n\n```%s\n' "$raw_language"
    if [[ "$captured_outputs_published" == true && "$stdout_usable" == true ]]; then
      cat "$raw_stdout"
    else
      printf '%s\n' '[REDACTED: raw output withheld; stdout.json/stderr.log failed path validation]'
    fi
    printf '\n```\n\n'
    printf '## Standard Error\n\n```text\n'
    if [[ "$captured_outputs_published" == true && "$stderr_usable" == true ]]; then
      cat "$raw_stderr"
    else
      printf '%s\n' '[REDACTED: standard error withheld; path validation failed]'
    fi
    printf '\n```\n\n'
    printf '## Sidecars\n\n- Execution: `%s`\n- Raw stdout: `%s`\n- Raw stderr: `%s`\n- Process tree: `%s`\n' "$execution_file" "$raw_stdout" "$raw_stderr" "$process_log"
    if [[ "$debug_mode" == true ]]; then
      printf -- '- Debug trace: `%s`\n' "$debug_output"
    fi
  } >"$temp_artifact" || return 1
  [[ "${ASK_CLAUDE_TEST_FAIL_FINAL_MV:-0}" != "1" ]] || return 1
  publish_artifact_file "$temp_artifact"
}

write_finalization_failure_artifact() {
  local temp_artifact="$artifact.finalization-failure.$$"
  artifact_stage_is_safe "$temp_artifact" || return 1
  {
    printf '# Claude Review: %s\n\n' "$slug"
    printf '> Status: `failed`\n\nArtifact finalization failed. See `%s`.\n' "$execution_file"
    emit_process_filter_warning
  } >"$temp_artifact" || return 1
  publish_artifact_file "$temp_artifact"
}

handle_signal() {
  local signal_name="$1" signal_code="$2"
  if [[ "$spawn_critical" == true ]]; then
    pending_signal="$signal_name"
    pending_signal_code="$signal_code"
    return 0
  fi
  trap '' INT TERM HUP
  termination_signal="$signal_name"
  status="interrupted"
  failure_reason="external_signal"
  timed_out=false
  runner_exit_code="$signal_code"
  cli_exit_code="$signal_code"
  stop_monitor
  if ! sidecar_dir_is_safe || ! sidecar_file_is_safe "$process_log" || ! [[ -f "$process_log" ]]; then
    record_tracking_error process_log_path_unsafe
  fi
  refresh_tracked_memory_from_log
  release_signal_processes
  if [[ -n "$review_pid" ]] && ! kill -0 "$review_pid" 2>/dev/null; then
    wait "$review_pid" 2>/dev/null || true
  fi
  finalize
  printf 'ARTIFACT=%s\n' "$artifact"
  # runner_exit_code starts as the signal code; if finalize's publication or
  # snapshot steps failed it was rewritten to 74/70 — propagate that so the
  # process exit never contradicts the machine record
  exit "$runner_exit_code"
}

trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM
trap 'handle_signal HUP 129' HUP
phase="review"
if [[ -n "${ASK_CLAUDE_TEST_SIGNAL_AFTER_START:-}" ]]; then
  kill "-${ASK_CLAUDE_TEST_SIGNAL_AFTER_START}" "$$"
fi

env_runner=(env)
if [[ "$watchdog_enabled" == true ]]; then
  env_runner+=(CLAUDE_CODE_RETRY_WATCHDOG=1)
else
env_runner+=(-u CLAUDE_CODE_RETRY_WATCHDOG)
fi
env_runner+=("TMPDIR=$provider_tmp")

spawn_critical=true
capture_is_regular "$raw_stdout_temp" || fail_preflight stdout_temp_unusable 73
capture_is_regular "$raw_stderr_temp" || fail_preflight stderr_temp_unusable 73
# spawn instant: the kill-after classification measures from here, not from
# preflight start, so preflight duration cannot leak into the timeout window
review_started_epoch_ms="$(epoch_ms)"
(
  cd "$repo_root" || exit 70
  exec "$timeout_bin" -k 5s "$timeout_value" ${sandbox_runner[@]+"${sandbox_runner[@]}"} "${env_runner[@]}" "$claude_bin" "${claude_args[@]}" <"$prompt_file"
) >"$raw_stdout_temp" 2>"$raw_stderr_temp" &
spawned_review_pid=$!
if [[ -n "${ASK_CLAUDE_TEST_SIGNAL_AFTER_SPAWN:-}" ]]; then
  kill "-${ASK_CLAUDE_TEST_SIGNAL_AFTER_SPAWN}" "$$"
fi
review_pid="$spawned_review_pid"
record_tree "$review_pid"
spawn_critical=false
if [[ -n "$pending_signal" ]]; then
  pending_signal_name="$pending_signal"
  pending_signal_exit_code="$pending_signal_code"
  pending_signal=""
  pending_signal_code=""
  handle_signal "$pending_signal_name" "$pending_signal_exit_code"
fi

running_tmp="$execution_file.running.$$"
if sidecar_file_is_safe "$running_tmp" && sidecar_file_is_safe "$execution_file"; then
  "$jq_bin" --argjson review_pid "$review_pid" '.review_pid = $review_pid | .phase = "review"' "$execution_file" >"$running_tmp" && sidecar_file_is_safe "$execution_file" && mv "$running_tmp" "$execution_file"
fi
monitor_tree "$review_pid" &
monitor_pid=$!

wait "$review_pid"
cli_exit_code=$?
stop_monitor

if [[ "$cli_exit_code" -eq 124 ]]; then
  status="timed_out"
  failure_reason="outer_timeout"
  timed_out=true
  runner_exit_code=124
elif [[ "$cli_exit_code" -eq 137 ]] && (( $(date +%s)000 - review_started_epoch_ms >= timeout_value_to_ms )); then
  # timeout -k reported 137 on this host when the wedged command ignored TERM
  # and the kill-after SIGKILL fired (coreutils probed 2026-09-22); elapsed is
  # measured from the SPAWN instant so preflight time cannot satisfy the test —
  # a genuine kill-after always lands at >= timeout, an external SIGKILL (OOM,
  # operator) must stay claude_exit_nonzero
  status="timed_out"
  failure_reason="outer_timeout_kill_after"
  timed_out=true
  runner_exit_code=137
elif [[ "$cli_exit_code" -ne 0 ]]; then
  status="failed"
  failure_reason="claude_exit_nonzero"
  timed_out=false
  runner_exit_code="$cli_exit_code"
elif [[ ! -s "$raw_stdout_temp" ]]; then
  status="failed"
  failure_reason="empty_stdout"
  timed_out=false
  runner_exit_code=65
elif ! "$jq_bin" -e 'type == "object"' "$raw_stdout_temp" >/dev/null 2>&1; then
  status="failed"
  failure_reason="invalid_json"
  timed_out=false
  runner_exit_code=65
else
  terminal_reason="$("$jq_bin" -r '.terminal_reason // ""' "$raw_stdout_temp")"
  models_json="$("$jq_bin" -c '(.modelUsage // {}) | keys | sort' "$raw_stdout_temp" 2>/dev/null)"
  models_json="${models_json:-[]}"
  model_usage_json="$("$jq_bin" -c '.modelUsage // {}' "$raw_stdout_temp")"
  usage_json="$("$jq_bin" -c '.usage // null' "$raw_stdout_temp")"
  permission_denials_json="$("$jq_bin" -c '.permission_denials // []' "$raw_stdout_temp")"
  structured_output_json="$("$jq_bin" -c '.structured_output // null' "$raw_stdout_temp")"
  claude_session_id="$("$jq_bin" -r '.session_id // ""' "$raw_stdout_temp")"
  claude_duration_ms_json="$("$jq_bin" -c '.duration_ms // null' "$raw_stdout_temp")"
  claude_duration_api_ms_json="$("$jq_bin" -c '.duration_api_ms // null' "$raw_stdout_temp")"
  if [[ "$terminal_reason" != "completed" ]]; then
    status="failed"
    failure_reason="invalid_terminal_reason"
    runner_exit_code=65
  elif "$jq_bin" -e '.is_error == true' "$raw_stdout_temp" >/dev/null 2>&1; then
    status="failed"
    failure_reason="claude_reported_error"
    runner_exit_code=65
  elif ! "$jq_bin" -e '
    .structured_output as $review |
    ($review | type == "object") and
    (($review | keys | sort) == ["caveats","findings","next_steps","verdict"]) and
    (["PASS","NEEDS_ATTENTION","BLOCKED"] | index($review.verdict) != null) and
    ($review.findings | type == "array") and
    (all($review.findings[];
      (. | type == "object") and
      (((keys - ["severity","file","line","issue","recommendation"]) | length) == 0) and
      (.severity | type == "string") and
      (.issue | type == "string") and
      (.recommendation | type == "string") and
      ((has("file") | not) or (.file | type == "string")) and
      ((has("line") | not) or (((.line | type) == "number") and (.line == (.line | floor)) and (.line > 0)))
    )) and
    ($review.caveats | type == "array") and
    (all($review.caveats[]; type == "string")) and
    ($review.next_steps | type == "array") and
    (all($review.next_steps[]; type == "string"))
  ' "$raw_stdout_temp" >/dev/null 2>&1; then
    status="failed"
    failure_reason="invalid_structured_output"
    runner_exit_code=65
  else
    status="completed"
    failure_reason=""
    timed_out=false
    runner_exit_code=0
  fi
fi

finalize
printf 'ARTIFACT=%s\n' "$artifact"
exit "$runner_exit_code"
