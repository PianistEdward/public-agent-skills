#!/usr/bin/env bash
# run_review.sh - macOS port of the ask-omp-review runner (Windows: run_review.ps1).
#
# Single execution path for the ask-omp-review skill. Encapsulates: deterministic
# run-id derivation, single-flight protection, diff export, Guarded write-deny
# config overlay, bounded event-driven wait with resume, and the completion
# contract. Never hand-roll a bare `omp` command from the host: stripping this
# runner removes the write-deny overlay, the pid tracking, and the contract.
#
# Usage:
#   run_review.sh --repo <path> --ref <ref> --prompt-file <file> [options]
#   run_review.sh --repo <path> --ref <ref> --export-diff [--diff-paths "a,b"]
#   run_review.sh --repo <path> --ref <ref> [--tag <same-tag>] --resume
#   run_review.sh --selftest
#
# Exit codes (aligned with the Windows runner):
#   0 = review collected (result non-empty and contains a Verdict line)
#   2 = preflight failure (omp missing, prompt missing, repo missing, ...)
#   3 = process exited but result empty
#   4 = wait budget exhausted, process still running (host re-invokes --resume)
#   5 = result non-empty but no Verdict line (truncated/corrupt output)
#   6 = git failure or empty diff on --export-diff
#   7 = single-flight: an omp process for this rid is already running (use --resume)
#   8 = --selftest assertion failure

set -u
RUNNER_VERSION="1.1.26"

# review artifacts may contain sensitive findings; keep them private even on
# the world-readable /tmp fallback
umask 077

usage() {
  cat <<'USAGE'
Usage: run_review.sh --repo <path> --ref <ref> [options]

Modes:
  (default)            Launch omp review, then bounded-wait for completion
  --export-diff        Export the review diff only (exit after CODE/DIFF line)
  --resume             Resume waiting on the already-launched run for this rid
  --selftest           Run static assertions, no network

Options:
  --repo <path>            Repository root (required)
  --ref <ref>              Review scope: HEAD-dirty | base..head | <commit> (required)
  --prompt-file <file>     Review instruction file (required for launch; @-referenced)
  --export-diff            Only export the diff and exit
  --diff-paths "a,b"       Limit the diff to comma-separated paths
  --diff-paths-file <file> Limit the diff to paths listed one-per-line in
                           <file> (# comments and blank lines ignored;
                           mutually exclusive with --diff-paths)
  --tag <label>            Disambiguation tag; rid = SHA256("repo|ref"[+"|"+tag])[:10]
                           (no trailing separator when --tag is omitted)
  --no-tools               Strict read-only static review (omp --no-tools)
  --tools "read,grep,glob" Restrict the tool registry to this list
  --bash-allow "c1,c2"     Extra bash allowlist patterns (comma-separated;
                           default: read-only git recon only)
  --max-time <dur>         omp hard timeout (default 30m; e.g. 45m, 1800)
  --wait-seconds <n>       Bounded wait budget per invocation (default 540)
  --model <selector>       Override omp model
  --yolo                   UNRESTRICTED (auto-approve all tools); trusted repos only
  -h, --help               Show this help

Status line (single ASCII line, key=value; ISO= is LAST because its value
contains spaces). Per-code shapes:
  CODE=0 EXITED=<n|?> RESULT=<bytes> ELAPSED=<s> RID=<rid> PID=<pid> OMPV=<ver> MODE=<mode> VERDICT=<APPROVE|REQUEST_CHANGES|?> RESULTFILE=<path> ERRFILE=<path> ISO=<isolation>
  CODE=3/5 REASON=<reason> ELAPSED=<s> RID=<rid> PID=<pid> EXITED=<n|?> MODE=<mode> RESULTFILE=<path> ERRFILE=<path> ISO=<isolation>
  CODE=4 ELAPSED=<s> RID=<rid> PID=<pid>            (still running; re-invoke --resume)
  CODE=0 DIFF=<path> DIFFBYTES=<n> RID=<rid> SKIPPED=<n> PARTIAL=<0|1>   (--export-diff success)
  CODE=6 REASON=<reason> RID=<rid> ERRFILE=<path> [DIFFBYTES=<n> SKIPPED=<n> PARTIAL=<0|1> on empty-diff]
  CODE=7 REASON=already_running|lost-claim RID=<rid> PID=<pid|?>
  CODE=2 REASON=error                               (die paths; no artifact fields)
USAGE
}

die() {
  # machine-readable status line on stdout (hosts parse it), human text on stderr
  printf 'CODE=%s REASON=error\n' "${2:-2}"
  printf 'ask-omp-review: %s\n' "$1" >&2
  exit "${2:-2}"
}
emit() { printf '%s\n' "$1"; }

# ---------- defaults ----------

repo_arg="" ref="" prompt_file="" diff_paths="" diff_paths_file="" tag="" tools_list="" bash_allow_extra=""
mode="launch" max_time="30m" wait_seconds="540" model="" yolo=false no_tools=false mode_explicit_export=0 resume_seen=0 tools_seen=0
repo="" ref="" rid="" tmp_dir="${TMPDIR:-/tmp}" prompt_file_abs="" omp_bin="" omp_version=""
# canonicalize: SBPL matches kernel-resolved paths — on macOS the raw
# $TMPDIR (/var/folders/...) and /tmp are symlink spellings of
# /private/var/... ; uncanonicalized -D literals never match (probed by the
# round-5 omp review: 5 of 6 artifact denies were inert)
tmp_dir="$(cd "$tmp_dir" && pwd -P)" || die "temp directory unavailable: $tmp_dir" 2

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) [[ $# -ge 2 ]] || die "--repo requires a value"; repo_arg="$2"; shift 2 ;;
    --ref) [[ $# -ge 2 ]] || die "--ref requires a value"; ref="$2"; shift 2 ;;
    --prompt-file) [[ $# -ge 2 ]] || die "--prompt-file requires a value"; prompt_file="$2"; shift 2 ;;
    --export-diff) mode="export"; mode_explicit_export=1; shift ;;
    --diff-paths) [[ $# -ge 2 ]] || die "--diff-paths requires a value"; diff_paths="$2"; shift 2 ;;
    --diff-paths-file) [[ $# -ge 2 ]] || die "--diff-paths-file requires a value"; diff_paths_file="$2"; shift 2 ;;
    --tag) [[ $# -ge 2 ]] || die "--tag requires a value"; tag="$2"; shift 2 ;;
    --no-tools) no_tools=true; shift ;;
    --tools) [[ $# -ge 2 ]] || die "--tools requires a value"; tools_list="$2"; tools_seen=1; shift 2 ;;
    --bash-allow)
      [[ $# -ge 2 ]] || die "--bash-allow requires a value"
      bash_allow_extra="$2"
      # validate here (preflight) so a bad pattern never consumes the prompt
      # or claims the rid before failing; a quote/newline/backslash would
      # break or inject into the overlay YAML
      # check the RAW value first: a newline would otherwise be split by the
      # line-wise loop below and silently truncate the pattern list
      [[ "$bash_allow_extra" == *$'\n'* ]] && die "unsupported --bash-allow value (embedded newline)" 2
      _ba_tmp="$bash_allow_extra"
      while IFS= read -r _ba_p; do
        [[ -n "$_ba_p" ]] || continue
        [[ "$_ba_p" == *'"'* || "$_ba_p" == *$'\n'* || "$_ba_p" == *'\'* ]] && die "unsupported --bash-allow pattern (quote/newline/backslash): $_ba_p" 2
      done < <(printf '%s\n' "$_ba_tmp" | tr ',' '\n')
      shift 2 ;;
    --max-time) [[ $# -ge 2 ]] || die "--max-time requires a value"; max_time="$2"; shift 2 ;;
    --wait-seconds) [[ $# -ge 2 ]] || die "--wait-seconds requires a value"; wait_seconds="$2"; shift 2 ;;
    --model) [[ $# -ge 2 ]] || die "--model requires a value"; model="$2"; shift 2 ;;
    --yolo) yolo=true; shift ;;
    --resume) mode="resume"; resume_seen=1; shift ;;
    --selftest) mode="selftest"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

# ---------- selftest (static, no network) ----------

run_selftest() {
  local failures=0
  pass() { printf 'PASS: %s\n' "$1"; }
  fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

  # rid derivation: deterministic, 10 chars, tag-sensitive
  local r1 r2 r3
  r1="$(derive_rid "/tmp/r" "HEAD-dirty" "")"
  r2="$(derive_rid "/tmp/r" "HEAD-dirty" "")"
  r3="$(derive_rid "/tmp/r" "HEAD-dirty" "t1")"
  [[ "$r1" == "$r2" && ${#r1} -eq 10 ]] && pass "rid deterministic, 10 chars" || fail "rid derivation"
  [[ "$r1" != "$r3" ]] && pass "rid changes with tag" || fail "rid tag sensitivity"
  r1="$(derive_rid "/tmp/r" "main..HEAD" "")"
  r2="$(derive_rid "/tmp/r2" "main..HEAD" "")"
  [[ "$r1" != "$r2" ]] && pass "rid changes with repo" || fail "rid repo sensitivity"

  # overlay invariants: write tools denied, catch-all deny present.
  # Every overlay tool/provider assertion greps the EXACT YAML line (grep -x):
  # a substring pattern is satisfied by any key that embeds it ("hub: deny"
  # lives inside "github: deny", "edit: deny" inside "ast_edit: deny",
  # "enableProjectConfig: false" inside this function's own header comment).
  # The bash-allowlist assertions further below keep substring grep -q —
  # each is uniquely binding because the closing quote disambiguates bare
  # and star forms ('match: "git diff"' cannot match 'match: "git diff *"').
  local overlay
  overlay="$(generate_overlay "")"
  printf '%s' "$overlay" | grep -qx "    edit: deny" && pass "overlay denies edit" || fail "overlay edit deny"
  printf '%s' "$overlay" | grep -qx "    write: deny" && pass "overlay denies write" || fail "overlay write deny"
  printf '%s' "$overlay" | grep -qx "    memory_edit: deny" && pass "overlay denies memory_edit" || fail "overlay memory_edit deny"
  for _t in recall reflect context_notes debug github; do
    printf '%s' "$overlay" | grep -qx "    ${_t}: deny" && pass "overlay denies $_t (read-tier auto-approved)" || fail "overlay $_t deny"
  done
  printf '%s' "$overlay" | grep -qx "    retain: deny" && pass "overlay denies retain (omp tiers it read; it writes user memory)" || fail "overlay retain deny"
  printf '%s' "$overlay" | grep -qx "  enableProjectConfig: false" && pass "overlay disables project MCP config" || fail "overlay mcp.enableProjectConfig"
  for _p in claude-plugins agent-plugins omp-plugins; do
    printf '%s' "$overlay" | grep -qx "  - ${_p}" && pass "overlay disables ${_p} provider" || fail "overlay ${_p} provider"
  done
  printf '%s' "$overlay" | grep -qx "    lsp: deny" && pass "overlay denies lsp" || fail "overlay lsp deny"
  printf '%s' "$overlay" | grep -qx "    manage_skill: deny" && pass "overlay denies manage_skill" || fail "overlay manage_skill deny"
  printf '%s' "$overlay" | grep -qx "    new_context: deny" && pass "overlay denies new_context" || fail "overlay new_context deny"
  printf '%s' "$overlay" | grep -qx "    learn: deny" && pass "overlay denies learn" || fail "overlay learn deny"
  printf '%s' "$overlay" | grep -qx "    eval: deny" && pass "overlay denies eval" || fail "overlay eval deny"
  printf '%s' "$overlay" | grep -qx "    web_search: deny" && pass "overlay denies web_search" || fail "overlay web_search deny"
  printf '%s' "$overlay" | grep -qx "    ast_edit: deny" && pass "overlay denies ast_edit" || fail "overlay ast_edit deny"
  printf '%s' "$overlay" | grep -qx "    task: deny" && pass "overlay denies task" || fail "overlay task deny"
  printf '%s' "$overlay" | grep -qx "    hub: deny" && pass "overlay denies hub" || fail "overlay hub deny"
  printf '%s' "$overlay" | grep -qx "disabledProviders:" && pass "overlay disables repo config/code providers" || fail "overlay disabledProviders"
  printf '%s' "$overlay" | grep -qx '  - "context-file:project:AGENTS.md"' && pass "overlay strips repo AGENTS.md" || fail "overlay disabledExtensions"
  printf '%s' "$overlay" | grep -qE 'match: "\*"' && pass "overlay has catch-all bash deny" || fail "overlay catch-all deny"
  printf '%s' "$overlay" | grep -q 'match: "git status \*"' && pass "overlay allows parameterized git status" || fail "overlay git status *"
  printf '%s' "$overlay" | grep -q 'match: "git diff"' && pass "overlay allows bare git diff" || fail "overlay bare git diff"
  printf '%s' "$overlay" | grep -q 'match: "git log"' && pass "overlay allows bare git log" || fail "overlay bare git log"
  printf '%s' "$overlay" | grep -q 'match: "git show"' && pass "overlay allows bare git show" || fail "overlay bare git show"

  # YAML shape: the appended catch-all must sit at the same indent as the
  # first sequence entry under bash.patterns (a dedent is a hard parse error)
  local _first_indent _catchall_indent
  _first_indent="$(printf '%s' "$overlay" | grep -m1 -E 'match: "git' | sed -E 's/[^ ].*//' | wc -c | tr -d ' ')"
  _catchall_indent="$(printf '%s' "$overlay" | grep -E 'match: "\*"' | sed -E 's/[^ ].*//' | wc -c | tr -d ' ')"
  [[ "$_first_indent" == "$_catchall_indent" && "$_first_indent" -gt 1 ]] && pass "catch-all indent matches sequence indent" || fail "overlay catch-all indent"
  overlay="$(generate_overlay "mvn test,mvn * test")"
  printf '%s' "$overlay" | grep -q 'match: "mvn test"' && pass "overlay honors --bash-allow" || fail "overlay bash-allow"

  # rid empty-tag encoding: hash input is "repo|ref" with NO trailing separator
  local rid_expected
  rid_expected="$(printf '%s' "/tmp/r|HEAD-dirty" | shasum -a 256 | cut -c1-10 | tr '[:lower:]' '[:upper:]')"
  [[ "$(derive_rid "/tmp/r" "HEAD-dirty" "")" == "$rid_expected" ]] && pass "rid empty-tag encoding matches docs" || fail "rid empty-tag encoding"

  # guarded argv contract: the 1.0.3 policy inversion must never silently
  # regress to --approval-mode write
  gf="$(guarded_extra_flags)"
  printf '%s' "$gf" | grep -q "always-ask" && pass "guarded flags use always-ask" || fail "guarded always-ask"
  for f in --no-lsp --no-rules --no-skills --no-extensions; do
    printf '%s' "$gf" | grep -q -- "$f" && pass "guarded flags include $f" || fail "guarded $f"
  done

  # completion contract helper
  assert_class() { # content expected_rc label
    local tf; tf="$(mktemp)"; printf '%s' "$1" >"$tf"
    classify_result "$tf" >/dev/null; local rc=$?
    rm -f "$tf"
    [[ "$rc" -eq "$2" ]] && pass "$3" || fail "$3"
  }
  local t; t="$(mktemp)"; printf 'some text\nVerdict: APPROVE\n' >"$t"
  classify_result "$t" >/dev/null; [[ $? -eq 0 ]] && pass "result with Verdict classifies 0" || fail "classify verdict"
  assert_class '### Verdict: REQUEST_CHANGES
' 0 "markdown heading Verdict classifies 0"
  assert_class 'Verdict: **REQUEST_CHANGES**
' 0 "bold-wrapped verdict value classifies 0"
  assert_class '**Verdict:** APPROVE
' 0 "bold-wrapped label classifies 0"
  assert_class '**Verdict**: APPROVE (colon outside bold)
' 0 "colon-outside-bold label classifies 0"
  assert_class 'Verdict: APPROVED (longer word)
' 5 "prefix word (APPROVED) does not classify"
  assert_class 'Verdict:	REQUEST_CHANGES (tab separator)
' 0 "tab separator classifies 0"
  assert_class 'Verdict:  APPROVE (double space)
' 0 "double-space separator classifies 0"
  assert_class 'text
- Verdict: APPROVE (list item, mid-line)
' 5 "list-item mid-line mention does not classify"
  assert_class ' context line
  Verdict: APPROVE (diff-context indent)
' 5 "diff-context indented mention does not classify"
  printf 'no verdict here\n' >"$t"; classify_result "$t" >/dev/null; [[ $? -eq 5 ]] && pass "result without Verdict classifies 5" || fail "classify no-verdict"
  printf 'text\n```\nVerdict: APPROVE\n```\n' >"$t"; classify_result "$t" >/dev/null; [[ $? -eq 5 ]] && pass "fenced-block verdict does not classify" || fail "classify fenced verdict"
  : >"$t"; classify_result "$t" >/dev/null; [[ $? -eq 3 ]] && pass "empty result classifies 3" || fail "classify empty"
  # CommonMark fence parity: a ~~~ line inside a ``` fence is literal content
  # (repo-quoted evidence must not flip the state and expose the verdict)
  printf 'text\n```\n~~~\nVerdict: APPROVE\n```\n' >"$t"; classify_result "$t" >/dev/null; [[ $? -eq 5 ]] && pass "tilde line inside backtick fence does not close it" || fail "classify mixed-fence escape"
  printf '```\n~~~\n```\nVerdict: APPROVE\n' >"$t"; classify_result "$t" >/dev/null; [[ $? -eq 0 ]] && pass "backtick fence closes after tilde content; later verdict classifies" || fail "classify mixed-fence close"
  printf '~~~\ntext\nVerdict: APPROVE\n~~~\n' >"$t"; classify_result "$t" >/dev/null; [[ $? -eq 5 ]] && pass "verdict inside tilde fence does not classify" || fail "classify tilde fence"
  # CommonMark indent bound: fences are fence lines only at 0-3 spaces of
  # indent; a 4+-space-indented line is indented-code literal content
  printf '```\n    ```\nVerdict: APPROVE\n    ```\n```\nVerdict: REQUEST_CHANGES\n' >"$t"; classify_result "$t" >/dev/null; [[ $? -eq 0 ]] && pass "indented fence line inside fence stays literal (classifies real verdict)" || fail "classify indent-bound escape"
  printf '    ```\ntext\nVerdict: APPROVE\n' >"$t"; classify_result "$t" >/dev/null; [[ $? -eq 0 ]] && pass "indented opener is not a fence; verdict classifies" || fail "classify phantom fence"

  # verdict extraction: FIRST Verdict occurrence wins; the labelled value is
  # extracted, not a later mention on the same line (regression: greedy sed)
  assert_verdict() { # content expected_verdict label
    local tf got; tf="$(mktemp)"; printf '%s' "$1" >"$tf"
    got="$(extract_verdict "$tf")"
    rm -f "$tf"
    [[ "$got" == "$2" ]] && pass "$3" || fail "$3 (got: ${got:-<empty>})"
  }
  assert_verdict '### Verdict: REQUEST_CHANGES
' "REQUEST_CHANGES" "extract heading verdict value"
  assert_verdict 'Verdict: **APPROVE**
' "APPROVE" "extract bold-wrapped value"
  assert_verdict '**Verdict:** APPROVE
' "APPROVE" "extract bold-wrapped label value"
  assert_verdict 'Verdict: REQUEST_CHANGES (Verdict: APPROVE would be wrong)
' "REQUEST_CHANGES" "first Verdict occurrence wins over later mention"
  assert_verdict 'some text
Verdict:	APPROVE (tab separator)
' "APPROVE" "extract tab-separated value"
  assert_verdict 'no verdict line
' "" "no verdict extracts empty"
  assert_verdict '```
~~~
Verdict: REQUEST_CHANGES
```
' "" "tilde inside backtick fence does not expose fenced verdict"
  assert_verdict '```
~~~
```
Verdict: REQUEST_CHANGES
' "REQUEST_CHANGES" "verdict after legitimately closed fence extracts"
  assert_verdict '```
    ```
Verdict: APPROVE
    ```
```
Verdict: REQUEST_CHANGES
' "REQUEST_CHANGES" "indented fence lines stay literal; first real verdict wins"
  assert_verdict '    ```
text
Verdict: APPROVE
' "APPROVE" "indented opener is not a fence; verdict extracts"
  rm -f "$t"

  # sandbox profile params must all be defined by the -D set and vice versa
  # (drift here means a profile apply failure or a silently dead rule). The
  # -D values come from the CRED_PATHS heredoc plus the two inline -D flags.
  # [A-Z0-9_] on both sides: digit-bearing params (M2_SETTINGS_FILE) must not
  # be silently exempt from the drift check.
  local _prof_params _d_params
  _prof_params="$(grep -o '(param "[A-Z0-9_]*")' "$0" | grep -o '"[A-Z0-9_]*"' | tr -d '"' | sort -u)"
  _d_params="$({ sed -n '/<<CRED_PATHS$/,/^CRED_PATHS$/p' "$0" | grep -oE '^[A-Z0-9_]+=' ; grep -oE -- '-D "[A-Z0-9_]+=' "$0" ; } | tr -d '="' | sed 's/^-D //' | sort -u)"
  [[ -n "$_prof_params" && "$_prof_params" == "$_d_params" ]] && pass "profile params == -D params (no drift)" || fail "profile/-D param drift"

  # credential read-deny canary lockstep: every credential deny rule in the
  # SANDBOX_PROFILE must have a probe candidate in the launch loop — a rule
  # without a candidate is a deny the canary can never verify (the ~/.azure
  # gap class). Candidates are matched to rules via the CRED_PATHS values.
  # (The converse drift — a candidate without a rule — fails closed at
  # runtime: the canary read would succeed and degrade the run honestly.)
  # CODEX_DIR/CLAUDE_DIR/AGENTS_SKILLS_DIR (config-injection surfaces) and
  # RUN_ROOT (runner-internal) are read-denied but deliberately unprobed.
  local _cred_params _cred_miss _cred_param _cred_path
  _cred_params="$(sed -n '/<<.SANDBOX_PROFILE./,/^SANDBOX_PROFILE$/p' "$0" \
    | grep -oE '^\(deny file-read\* \((subpath|literal) \(param "[A-Z0-9_]+"\)\)\)' \
    | grep -oE '"[A-Z0-9_]+"' | tr -d '"' | sort -u \
    | grep -vxE 'CODEX_DIR|CLAUDE_DIR|AGENTS_SKILLS_DIR|RUN_ROOT')"
  _cred_miss=""
  for _cred_param in $_cred_params; do
    _cred_path="$(sed -n '/<<CRED_PATHS$/,/^CRED_PATHS$/p' "$0" | sed -n "s/^${_cred_param}=//p")"
    if [[ -z "$_cred_path" ]]; then
      _cred_miss="$_cred_miss $_cred_param(no-CRED_PATHS-entry)"
    elif ! awk '/for _cd in/,/; do/' "$0" | grep -qF "\"$_cred_path\""; then
      _cred_miss="$_cred_miss $_cred_param"
    fi
  done
  [[ -n "$_cred_params" && -z "$_cred_miss" ]] && pass "credential canary probes cover every profile credential deny" || fail "credential denies without canary probe:$_cred_miss"

  # variables expanded by the CRED_PATHS heredoc must be defined BEFORE it
  # (an unquoted heredoc expands at run time; a later definition crashed
  # every launch under set -u — caught live, now pinned here)
  local _cp_start _bad_vars _vname _vline
  _cp_start="$(grep -nE 'done <<CRED_PATHS[[:space:]]*$' "$0" | head -1 | cut -d: -f1)"
  _bad_vars=""
  for _vname in repo_toplevel git_dir git_common_dir omp_skill_dir tmp_dir run_root run_dir home_canary overlay_file omp_bin omp_bin_real; do
    _vline="$(grep -nE "^[[:space:]]*${_vname}=" "$0" | head -1 | cut -d: -f1)"
    if [[ -z "$_cp_start" || -z "$_vline" || "$_vline" -gt "$_cp_start" ]]; then
      _bad_vars="$_bad_vars $_vname"
    fi
  done
  [[ -z "$_bad_vars" ]] && pass "CRED_PATHS variables are defined before expansion" || fail "CRED_PATHS expands variables defined later:$_bad_vars"

  # SBPL last-match-wins ordering must hold where it is load-bearing:
  # (a) the omp runtime store re-allows must come AFTER the WORKSPACE deny
  #     (else --repo $HOME voids them → SQLITE_READONLY);
  # (b) the secret read-denies must come AFTER the read re-allows
  #     (else a toplevel containing a credential store voids the denies).
  local _ln_ws_deny _ln_db_allow _ln_read_allow _ln_secret_deny
  _ln_ws_deny="$(grep -n '(deny file-write\* (subpath (param "WORKSPACE")))' "$0" | tail -1 | cut -d: -f1)"
  _ln_db_allow="$(grep -n '(allow file-write\* (literal (param "OMP_AGENT_DB")))' "$0" | tail -1 | cut -d: -f1)"
  _ln_read_allow="$(grep -n '(allow file-read\* (subpath (param "WORKSPACE")))' "$0" | tail -1 | cut -d: -f1)"
  _ln_secret_deny="$(grep -n '(deny file-read\* (subpath (param "SSH_DIR")))' "$0" | tail -1 | cut -d: -f1)"
  if [[ -n "$_ln_ws_deny" && -n "$_ln_db_allow" && "$_ln_db_allow" -gt "$_ln_ws_deny" ]]; then
    pass "runtime store re-allow follows the WORKSPACE write deny"
  else
    fail "runtime store re-allow must follow the WORKSPACE write deny"
  fi
  local _ln_tmp_allow
  _ln_tmp_allow="$(grep -n '(allow file-write\* (subpath (param "TMP_DIR")))' "$0" | tail -1 | cut -d: -f1)"
  if [[ -n "$_ln_ws_deny" && -n "$_ln_tmp_allow" && "$_ln_ws_deny" -gt "$_ln_tmp_allow" ]]; then
    pass "target write-deny re-asserted after the TMP_DIR allow"
  else
    fail "target write-deny must be re-asserted after the TMP_DIR allow"
  fi
  if [[ -n "$_ln_read_allow" && -n "$_ln_secret_deny" && "$_ln_secret_deny" -gt "$_ln_read_allow" ]]; then
    pass "secret read-denies follow the review-target read re-allows"
  else
    fail "secret read-denies must follow the review-target read re-allows"
  fi

  if [[ "$failures" -ne 0 ]]; then printf '%d selftest check(s) failed.\n' "$failures" >&2; exit 8; fi
  printf 'ask-omp-review selftest passed.\n'
  exit 0
}

# ---------- helpers ----------

derive_rid() { # repo ref tag -> 10-char uppercase sha256 prefix
  printf '%s' "$1|$2${3:+|$3}" | shasum -a 256 | cut -c1-10 | tr '[:lower:]' '[:upper:]'
}

# Guarded config overlay: write tools denied; bash restricted to allowlist
# patterns. Schema verified against omp 18.1.18 (binary strings + live smoke
# 2026-09-22): bash approval rules live under the TOP-LEVEL `bash.patterns`
# key, each item {match, approval} with only '*' wildcards; per-tool policies
# live under tools.approval.<tool>: allow|prompt|deny.
generate_overlay() { # extra_bash_allow_csv -> yaml on stdout
  local extra_csv="$1" p
  cat <<'OVERLAY_HEAD'
# strip the reviewed repo's own omp config/code surface: deep-merged per-tool
# allow keys (e.g. tools.approval.eval: allow) and code-bearing providers
# (hooks/tools/extensions) in <repo>/.omp would otherwise survive the overlay.
# The *-plugins providers are denied too: they scan PROJECT-LEVEL plugin
# registries/dirs (.claude/plugins/installed_plugins.json, agent-plugins
# standard dirs, explicit extension roots) and ship hooks/skills/MCP whose
# project-scope MCP servers would be CONNECTED (stdio command spawned) because
# mcp.enableProjectConfig defaults true — --no-extensions only gates ambient
# extension-module discovery, not plugin package surfaces. The explicit
# mcp.enableProjectConfig: false is the second layer (blocks every
# project-level MCP server regardless of provider id).
disabledProviders:
  - native
  - claude
  - claude-plugins
  - codex
  - gemini
  - opencode
  - agents
  - agent-plugins
  - omp-plugins
  - agents-md
  - claude-md
  - github
  - cursor
  - windsurf
  - cline
  - vscode
  - mcp-json
  - ssh-json
disabledExtensions:
  - "context-file:project:AGENTS.md"
  - "context-file:project:CLAUDE.md"
  - "context-file:project:GEMINI.md"
tools:
  approval:
    edit: deny
    write: deny
    ast_edit: deny
    memory_edit: deny
    retain: deny
    recall: deny
    reflect: deny
    context_notes: deny
    lsp: deny
    manage_skill: deny
    new_context: deny
    learn: deny
    eval: deny
    task: deny
    hub: deny
    web_search: deny
    debug: deny
    github: deny
mcp:
  enableProjectConfig: false
bash:
  patterns:
    - match: "git status"
      approval: allow
    - match: "git status *"
      approval: allow
    - match: "git diff"
      approval: allow
    - match: "git diff *"
      approval: allow
    - match: "git log"
      approval: allow
    - match: "git log *"
      approval: allow
    - match: "git show"
      approval: allow
    - match: "git show *"
      approval: allow
    - match: "git rev-parse"
      approval: allow
    - match: "git rev-parse *"
      approval: allow
OVERLAY_HEAD
  if [[ -n "$extra_csv" ]]; then
    IFS=',' read -r -a _extra <<<"$extra_csv"
    for p in "${_extra[@]}"; do
      [[ -n "$p" ]] || continue
      # a quote/newline/backslash would break or inject into the overlay YAML
      [[ "$p" == *'"'* || "$p" == *$'\n'* || "$p" == *'\'* ]] && die "unsupported --bash-allow pattern (quote/newline/backslash): $p" 2
      printf '    - match: "%s"\n      approval: allow\n' "$p"
    done
  fi
  printf '    - match: "*"\n      approval: deny\n'
}

# Guarded extra flags (single source of truth; selftest asserts them):
# always-ask so every write/exec-tier tool fail-closes in print mode (write
# mode auto-approves ALL read/write-tier tools — lsp, manage_skill, MCP);
# no-lsp because a reviewed repo can ship lsp.json spawning an attacker
# command; no-rules/no-skills because reviewed-repo AGENTS.md/CLAUDE.md
# injection could fabricate the completion verdict; no-extensions because
# the reviewed repo's .omp/hooks|tools|extensions are code loaded into the
# reviewer process (combined with disabledProviders/disabledExtensions in
# the overlay, which also strip the repo's .omp/config.yml per-tool allow
# keys that would otherwise deep-merge over the overlay).
guarded_extra_flags() { printf '%s' "--approval-mode always-ask --no-lsp --no-rules --no-skills --no-extensions"; }

# completion contract: 0 = has Verdict, 3 = empty, 5 = no Verdict.
# Anchored to line start: optional markdown heading/bold decorations, then
# "Verdict:", with the value allowed to be bold-wrapped (**X** — observed in
# real reviewer output). A bare leading space (diff-context lines) does NOT
# match, so reviewed content cannot satisfy the contract on a truncated or
# quoted result.
classify_result() { # result_file -> exit code per contract
  local f="$1"
  [[ -s "$f" ]] || return 3
  # Fenced code blocks are excluded (CommonMark fence parity, shared with
  # extract_verdict below): a quoted prior verdict inside ``` must not
  # satisfy the contract on a truncated result. A close must reuse the
  # opener's character with at least the opener's length and carry nothing
  # but whitespace — a ~~~ line inside a ``` fence is literal content, so
  # repo-quoted evidence cannot flip the state and expose an in-fence
  # "Verdict:" line. (The label may be bold-wrapped (**Verdict:** X), the
  # value may be bold-wrapped, and a word-boundary terminator rejects
  # APPROVED-style prefixes.)
  if awk '
    # CommonMark fence parity (shared with extract_verdict below): fences are
    # recognized only at 0-3 spaces of indent (4+ spaces is an indented code
    # block — literal content, not a fence line), and a close must reuse the
    # opener'"'"'s character with at least the opener'"'"'s length and carry nothing
    # but whitespace — a ~~~ line inside a ``` fence, or a space-indented
    # fence line inside quoted evidence, cannot flip the state and expose an
    # in-fence "Verdict:" line. Tab-led fence-shaped lines are treated as
    # literal (conservative fail-closed).
    /^[ ]{0,3}(`{3,}|~{3,})/ {
      s = $0; sub(/^[ ]{0,3}/, "", s)
      if (match(s, /^(`{3,}|~{3,})/)) {
        ch = substr(s, RSTART, 1); fl = RLENGTH
        if (infence == "") { infence = ch; flen = fl }
        else if (ch == infence && fl >= flen && substr(s, fl + 1) ~ /^[[:space:]]*$/) { infence = ""; flen = 0 }
      }
      next
    }
    !infence && /^([#*]+[[:space:]]*)?\*{0,2}Verdict\*{0,2}:\*{0,2}[[:space:]]*\*{0,2}(APPROVE|REQUEST_CHANGES)([^A-Za-z_]|$)/ { found = 1 }
    END { exit(found ? 0 : 5) }
  ' "$f"; then
    return 0
  fi
  return 5
}

pid_alive() { kill -0 "$1" 2>/dev/null; }

# Value of the FIRST contract Verdict line (empty when absent). Uses the same
# line/fence anchors as classify_result (CommonMark fence parity — see the
# rationale there); first match() binds the labelled value so a second
# "Verdict:" mention later on the line cannot flip the extraction.
extract_verdict() { # result_file -> APPROVE|REQUEST_CHANGES|"" on stdout
  awk '
    /^[ ]{0,3}(`{3,}|~{3,})/ {
      s = $0; sub(/^[ ]{0,3}/, "", s)
      if (match(s, /^(`{3,}|~{3,})/)) {
        ch = substr(s, RSTART, 1); fl = RLENGTH
        if (infence == "") { infence = ch; flen = fl }
        else if (ch == infence && fl >= flen && substr(s, fl + 1) ~ /^[[:space:]]*$/) { infence = ""; flen = 0 }
      }
      next
    }
    !infence && !found && /^([#*]+[[:space:]]*)?\*{0,2}Verdict\*{0,2}:\*{0,2}[[:space:]]*\*{0,2}(APPROVE|REQUEST_CHANGES)([^A-Za-z_]|$)/ {
      if (match($0, /(APPROVE|REQUEST_CHANGES)([^A-Za-z_]|$)/)) {
        v = substr($0, RSTART, RLENGTH)
        sub(/[^A-Za-z_]$/, "", v)
        print v
      }
      found = 1
    }
  ' "$1"
}

# ---------- exclusivity and sanity checks ----------

[[ "$yolo" == true && "$no_tools" == true ]] && die "--yolo and --no-tools are mutually exclusive" 2
[[ "$yolo" == true && -n "$tools_list" ]] && die "--yolo and --tools are mutually exclusive" 2
[[ "$yolo" == true && -n "$bash_allow_extra" ]] && die "--bash-allow has no effect with --yolo" 2
[[ "${tools_seen:-0}" == 1 && -z "$tools_list" ]] && die "--tools requires a non-empty list (use --no-tools to strip all tools)" 2
[[ "$no_tools" == true && -n "$tools_list" ]] && die "--no-tools and --tools are mutually exclusive" 2
[[ "$no_tools" == true && -n "$bash_allow_extra" ]] && die "--bash-allow has no effect with --no-tools" 2
[[ "$resume_seen" == 1 && "$mode_explicit_export" == 1 ]] && die "--export-diff and --resume are mutually exclusive" 2
[[ "$ref" == *\|* || "$tag" == *\|* || "$repo_arg" == *\|* ]] && die "--repo/--ref/--tag must not contain '|' (rid derivation separator)" 2
[[ "$wait_seconds" =~ ^[0-9]+$ ]] || die "--wait-seconds must be a non-negative integer" 2
wait_seconds=$((10#$wait_seconds))   # base-10: "09" is not an octal literal
# --diff-paths-file: one path per line; blank lines and #-comments ignored.
# Populated into the same diff_paths CSV the --diff-paths flag feeds, so the
# export-only check below covers both spellings.
if [[ -n "$diff_paths_file" ]]; then
  [[ -z "$diff_paths" ]] || die "--diff-paths and --diff-paths-file are mutually exclusive" 2
  [[ -f "$diff_paths_file" && -s "$diff_paths_file" ]] || die "--diff-paths-file is missing or empty: $diff_paths_file" 2
  _dpf_clean=()
  while IFS= read -r _dpf_line || [[ -n "$_dpf_line" ]]; do
    _dpf_line="${_dpf_line%$'\r'}"
    _dpf_line="$(printf '%s' "$_dpf_line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -z "$_dpf_line" || "$_dpf_line" == \#* ]] && continue
    _dpf_clean+=("$_dpf_line")
  done < "$diff_paths_file"
  [[ ${#_dpf_clean[@]} -gt 0 ]] || die "--diff-paths-file contains no valid entries" 2
  diff_paths="$(IFS=,; printf '%s' "${_dpf_clean[*]}")"
fi
[[ -n "$diff_paths" && "$mode_explicit_export" != 1 ]] && die "--diff-paths applies to --export-diff only" 2

# ---------- selftest branch ----------

[[ "$mode" == "selftest" ]] && run_selftest

# ---------- preflight ----------

[[ -n "$repo_arg" ]] || die "--repo is required" 2
[[ -d "$repo_arg" ]] || die "repo directory does not exist: $repo_arg" 2
repo="$(cd "$repo_arg" && pwd -P)" || die "repo path unusable: $repo_arg" 2
[[ -n "$ref" ]] || die "--ref is required (HEAD-dirty | base..head | <commit>)" 2
[[ "$ref" == -* ]] && die "--ref must not start with '-'" 2

rid="$(derive_rid "$repo" "$ref" "$tag")"
[[ -d "$tmp_dir" ]] || mkdir -p "$tmp_dir" 2>/dev/null || true
[[ -w "$tmp_dir" ]] || die "temp directory not writable: $tmp_dir" 2
# per-run private directory: every runner artifact lives under it, so a single
# (deny file-write* (subpath RUN_DIR)) protects this invocation's result,
# state sidecar, prompt and overlays from ANY other sandboxed run (SBPL has
# no wildcard, so sibling-name literals could never express that boundary)
# per-run private directory under a shared, profile-denied parent: RUN_ROOT
# covers ALL runs' artifact trees (result/state/prompt/overlay), so a
# sandboxed reviewer cannot touch a sibling run's files either
run_root="$tmp_dir/omp-review"
# rid is derivable from public inputs, so on a world-writable TMPDIR fallback
# a hostile local account can pre-create the run tree; a foreign-owned parent
# would let it rename/replace artifacts between runner writes and omp reads
# (swap the prompt, pre-plant result.md). Refuse any pre-existing tree we do
# not own — fail-closed, consistent with the symlink refusals below.
[[ -L "$run_root" ]] && die "refusing to follow pre-existing symlink: $run_root" 2
[[ -d "$run_root" && ! -O "$run_root" ]] && die "refusing pre-existing run root not owned by this user: $run_root" 2
mkdir -p "$run_root" || die "cannot create run root: $run_root" 2
# a pre-existing owned root can carry loose group/world perms (an older
# runner version or another tool created it); tighten so a same-group peer
# cannot rename/replace entries — the exact artifact-swap scenario the
# ownership check exists to prevent. No-op for dirs we just created (umask 077).
chmod 700 "$run_root" 2>/dev/null || die "cannot tighten run root permissions: $run_root" 2
run_dir="$run_root/$rid"
[[ -L "$run_dir" ]] && die "refusing to follow pre-existing symlink: $run_dir" 2
[[ -d "$run_dir" && ! -O "$run_dir" ]] && die "refusing pre-existing run directory not owned by this user: $run_dir" 2
mkdir -p "$run_dir" || die "cannot create run directory: $run_dir" 2
chmod 700 "$run_dir" 2>/dev/null || die "cannot tighten run directory permissions: $run_dir" 2
pid_file="$run_dir/pid"
result_file="$run_dir/result.md"
err_file="$run_dir/err.txt"
state_file="$run_dir/state"
overlay_file="$run_dir/config.yml"
sandbox_profile_file="$run_dir/sandbox.sb"
export_err="$run_dir/export-err.txt"
launched_at="$(date +%s)"

# never follow a pre-placed symlink for any runner-owned temp path
# (rid is derivable from public inputs; /tmp fallback is world-writable)
for _owned in "$pid_file" "$result_file" "$err_file" "$state_file" "$overlay_file" "$sandbox_profile_file" "$run_dir/prompt.md"; do
  [[ -L "$_owned" ]] && die "refusing to follow pre-existing symlink: $_owned" 2
done

# ---------- export-diff mode ----------

if [[ "$mode" == "export" ]]; then
  diff_file=""
  # CODE=6 paths carry RID/ERRFILE per the documented contract (the generic
  # `die` shape is reserved for CODE=2 preflight failures)
  export_die() { emit "CODE=6 REASON=export-failure RID=$rid ERRFILE=$export_err"; exit 6; }
  if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    gd="$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)" || export_die
    mkdir -p "$gd/review-cache" || export_die
    [[ -L "$gd/review-cache" ]] && die "refusing to follow pre-existing symlink: $gd/review-cache" 2
    diff_file="$gd/review-cache/omp-review-$rid.diff"
    # effective path scope, persisted for host verification: a long
    # hand-maintained list is easy to get wrong and a silently dropped path
    # shrinks the review without any signal. The status line carries the
    # count (DIFFPATHS=), the run dir carries the one-per-line list.
    diffpaths_count=0
    if [[ -n "$diff_paths" ]]; then
      printf '%s\n' "$diff_paths" | tr ',' '\n' >"$run_dir/diff-paths.txt"
      diffpaths_count="$(grep -c . "$run_dir/diff-paths.txt")"
    fi
    [[ -L "$diff_file" ]] && die "refusing to follow pre-existing symlink: $diff_file" 2
    [[ -L "$export_err" ]] && die "refusing to follow pre-existing symlink: $export_err" 2
    # write via tmp+mv: the temp lives in RUN_DIR (never in the reviewed
    # repo's git dir, so an interrupted export leaves no litter there) and is
    # renamed into review-cache only on success
    diff_tmp="$(mktemp "$run_dir/diff.XXXXXX")" || export_die
    : >"$diff_tmp"
    diff_args_extra=()
    # hardening: the export runs UNSANDBOXED in the runner process and
    # inherits repo config — a hostile .git/config could ship diff.external/
    # textconv drivers (arbitrary exec). The -c flags in diff_config
    # neutralize the config-driven execution vectors on EVERY export-path
    # git call that can execute them:
    #   diff.external=        — external diff driver (the diff/show calls)
    #   log.showSignature=    — signature verification (gpg.program exec) on
    #                           the `git show` path
    #   core.fsmonitor=       — fsmonitor hook daemon, spawned on index
    #                           refresh: `git diff`/`git show` AND
    #                           `git ls-files --others` (live-probed) all
    #                           refresh, so the ls-files call carries it too
    # --no-ext-diff/--no-textconv are the diff-option belt to the -c braces.
    # The plain rev-parse probes cannot execute config-driven hooks.
    # NOT neutralizable: .gitattributes-mapped filter.<name>.clean content
    # filters run during diff — on stat-dirty worktree files AND on
    # attribute-matched untracked files in the --no-index pass (live-probed,
    # no stat-dirty precondition there) — and have no enumerable kill switch
    # (definitions live in the hostile .git/config, mappings in the
    # worktree): residual, documented in SKILL.md's trust section
    # (untrusted-repo exports belong on a sanitized copy).
    diff_flags=(--no-ext-diff --no-textconv)
    diff_config=(-c diff.external= -c log.showSignature=false -c core.fsmonitor=false)
    case "$ref" in
      HEAD-dirty*)
        # unborn repo (git init, no commits): the change may be STAGED and
        # then MODIFIED in the worktree — export BOTH the index (git diff
        # --cached) and the worktree delta (git diff), otherwise part of the
        # change silently disappears from the review
        if git -C "$repo" rev-parse --verify -q HEAD >/dev/null 2>&1; then
          diff_args=(diff "${diff_flags[@]}" HEAD -U10)
        else
          diff_args=(diff "${diff_flags[@]}" --cached -U10)
          diff_args_extra=(diff "${diff_flags[@]}" -U10)
        fi ;;
      *..*) diff_args=(diff "${diff_flags[@]}" -U10 "$ref") ;;
      *) diff_args=(show "${diff_flags[@]}" "$ref" -U10) ;;
    esac
    # pathspecs attach to the tracked commands — an empty diff_args plus a
    # "--" tail would form a top-level `git -- <path>`
    if [[ -n "$diff_paths" ]]; then
      IFS=',' read -r -a _dp <<<"$diff_paths"
      _dp_clean=()
      for _p in "${_dp[@]}"; do [[ -n "$_p" ]] && _dp_clean+=("$_p"); done
      [[ ${#_dp_clean[@]} -gt 0 ]] || die "--diff-paths contains no valid entries" 2
      [[ ${#diff_args[@]} -gt 0 ]] && diff_args+=("--" "${_dp_clean[@]}")
      [[ ${#diff_args_extra[@]} -gt 0 ]] && diff_args_extra+=("--" "${_dp_clean[@]}")
    fi
    if [[ ${#diff_args[@]} -gt 0 ]]; then
      if ! git -C "$repo" ${diff_config[@]+"${diff_config[@]}"} "${diff_args[@]}" >"$diff_tmp" 2>"$export_err"; then
        rm -f "$diff_tmp"
        emit "CODE=6 REASON=git-failure RID=$rid ERRFILE=$export_err"
        exit 6
      fi
    fi
    # HEAD-dirty is tracked-only by nature; agent-authored changes are often
    # untracked-only, so append new-file diffs for untracked paths (scoped by
    # --diff-paths when provided — the limiter must also shrink this pass).
    # -z NUL-delimited so adversarially-named files cannot hide from review.
    skipped=0
    # the unborn worktree-delta pass is counted too: a silent partial diff
    # must surface as SKIPPED/PARTIAL instead of a clean CODE=0
    partial=0
    # exported worktree paths, for the HEAD-dirty fingerprint (.fp sibling):
    # a frozen diff never tracks the worktree — an edit landing between
    # export and review leaves the review reading stale content, and in
    # --no-tools mode the reviewer cannot notice. The fingerprint (content
    # hash per exported path) makes that drift detectable after the fact.
    exported_files=()
    if [[ "$ref" == HEAD-dirty* ]]; then
      if git -C "$repo" rev-parse --verify -q HEAD >/dev/null 2>&1; then
        while IFS= read -r -d '' p; do [[ -n "$p" ]] && exported_files+=("$p"); done < \
          <(git -C "$repo" ${diff_config[@]+"${diff_config[@]}"} diff --name-only -z HEAD 2>/dev/null)
      else
        while IFS= read -r -d '' p; do [[ -n "$p" ]] && exported_files+=("$p"); done < \
          <(git -C "$repo" ${diff_config[@]+"${diff_config[@]}"} diff --name-only -z --cached 2>/dev/null)
      fi
    fi
    if [[ ${#diff_args_extra[@]} -gt 0 ]]; then
      git -C "$repo" ${diff_config[@]+"${diff_config[@]}"} "${diff_args_extra[@]}" >>"$diff_tmp" 2>>"$export_err"
      [[ $? -ge 2 ]] && partial=1
    fi
    if [[ "$ref" == HEAD-dirty* ]]; then
      _untracked_args=(ls-files -z --others --exclude-standard)
      if [[ -n "$diff_paths" ]]; then
        IFS=',' read -r -a _dp <<<"$diff_paths"
        _dp_clean=()
        for _p in "${_dp[@]}"; do [[ -n "$_p" ]] && _dp_clean+=("$_p"); done
        [[ ${#_dp_clean[@]} -gt 0 ]] || die "--diff-paths contains no valid entries" 2
        _untracked_args+=("--" "${_dp_clean[@]}")
      fi
      while IFS= read -r -d '' u; do
        [[ -n "$u" ]] || continue
        # an untracked entry can be any node type an adversary plants in the
        # worktree; git's --no-index content read opens the path, so a FIFO
        # would block until a writer appears (spurious CODE=4). Only regular
        # files and symlinks are diffable — count the rest in SKIPPED=,
        # consistent with the existing skip accounting. NOTE: $u is relative
        # to the REPO root (ls-files output), so the type test must be
        # repo-anchored — a cwd-relative -f would skip every entry when the
        # runner is invoked from outside the repository.
        [[ -f "$repo/$u" || -L "$repo/$u" ]] || { skipped=$((skipped + 1)); continue; }
        exported_files+=("$u")
        # git diff --no-index: 0 = identical, 1 = differences (success),
        # >=2 = real trouble. Hardened like every runner-side diff call
        # (worktree-controlled input, unsandboxed runner process).
        git -C "$repo" ${diff_config[@]+"${diff_config[@]}"} diff --no-ext-diff --no-textconv --no-index -- /dev/null "$u" >>"$diff_tmp" 2>>"$export_err"
        rc=$?
        if [[ $rc -ge 2 ]]; then
          skipped=$((skipped + 1))
        fi
      done < <(git -C "$repo" ${diff_config[@]+"${diff_config[@]}"} -c core.quotepath=false "${_untracked_args[@]}")
    fi
    mv "$diff_tmp" "$diff_file" || export_die
    bytes=0
    [[ -f "$diff_file" ]] && bytes="$(wc -c <"$diff_file" | tr -d ' ')"
    if [[ "$bytes" -lt 64 ]]; then
      emit "CODE=6 REASON=empty-diff RID=$rid DIFFBYTES=$bytes ERRFILE=$export_err SKIPPED=$skipped PARTIAL=$partial DIFFPATHS=$diffpaths_count"
      exit 6
    fi
    # HEAD-dirty fingerprint (sibling <diff>.fp): content hash per exported
    # worktree path + diff hash. Committed-range exports are immutable, so
    # only worktree snapshots need one. Recompute the hashes later and
    # compare to detect worktree edits that landed after the export (the
    # frozen diff does not follow the worktree). Symlinks are recorded by
    # target string (shasum would dereference, and a symlink may point at a
    # FIFO — the same reason the diff loop avoids dereferencing).
    fp_value=""
    if [[ "$ref" == HEAD-dirty* ]]; then
      fp_entry() { # repo-relative path -> "<hash>  <path>" on stdout
        if [[ -f "$repo/$1" ]]; then
          printf '%s  %s\n' "$(shasum -a 256 <"$repo/$1" | awk '{print $1}')" "$1"
        elif [[ -L "$repo/$1" ]]; then
          printf 'symlink:%s  %s\n' "$(readlink "$repo/$1" 2>/dev/null || printf '?')" "$1"
        else
          printf 'missing  %s\n' "$1"
        fi
      }
      _fp_file="$diff_file.fp"
      {
        printf '# omp-review export fingerprint (HEAD-dirty worktree snapshot)\n'
        printf '# the frozen diff does NOT track the worktree: if any hash below no longer\n'
        printf '# matches the file, the review read stale content — re-export and re-review.\n'
        printf 'head=%s\n' "$(git -C "$repo" rev-parse --verify -q HEAD 2>/dev/null || printf 'unborn')"
        printf 'generated=%s\n' "$(date +%s)"
        printf 'diff_sha256=%s\n' "$(shasum -a 256 <"$diff_file" | awk '{print $1}')"
        for _p in ${exported_files[@]+"${exported_files[@]}"}; do fp_entry "$_p"; done
      } >"$_fp_file" 2>/dev/null || true
      if [[ -s "$_fp_file" ]]; then
        fp_value="$(shasum -a 256 <"$_fp_file" | awk '{print $1}')"
        fp_value="${fp_value:0:10}"
      fi
    fi
    emit "CODE=0 DIFF=$diff_file DIFFBYTES=$bytes RID=$rid SKIPPED=$skipped PARTIAL=$partial DIFFPATHS=$diffpaths_count${fp_value:+ FP=$fp_value}"
    exit 0
  else
    emit "CODE=6 REASON=not-a-git-repo RID=$rid ERRFILE=$export_err"
    exit 6
  fi
fi

# ---------- omp preflight (launch only; export needs just git, resume reads state) ----------

if [[ "$mode" == "launch" ]]; then
  command -v omp >/dev/null 2>&1 || die "omp CLI not found in PATH (install oh-my-pi / omp first)" 2
  omp_bin="$(command -v omp)"
  omp_version="$(omp --version 2>/dev/null | head -1 | awk -F/ '{print $2}')"
fi

# ---------- launch preflight (launch + resume) ----------

if [[ "$yolo" == true ]]; then mode_label="yolo"; elif [[ "$no_tools" == true ]]; then mode_label="no-tools"; else mode_label="guarded"; fi

wait_needed=true
iso="prompt-only (sandbox-exec unavailable; boundary not enforcing)"

if [[ "$mode" == "resume" ]]; then
  # resume may find the run already finished within the CODE=4 gap: fall
  # through to the classification tail instead of dying, so a complete
  # review is not orphaned as CODE=2
  wait_needed=true
  opid=""
  if [[ -f "$pid_file" ]]; then
    opid="$(cut -d'|' -f1 "$pid_file")"
  fi
  if [[ -n "$opid" && "$opid" =~ ^[0-9]+$ && "$opid" != 0 ]] && pid_alive "$opid"; then
    :
  elif [[ -f "$result_file" ]]; then
    wait_needed=false
    opid="${opid:-?}"
  else
    die "pidfile missing/untrusted for rid $rid and no result file; nothing to resume (launch first)" 2
  fi
  # ELAPSED counts from the original launch, not from resume time; the
  # effective isolation and mode come from the sidecar (resume-time flags
  # only carry --repo/--ref/--tag/--resume)
  if [[ -f "$state_file" ]]; then
    _launched="$(sed -n 's/^launched=//p' "$state_file" | tail -1)"
    [[ "$_launched" =~ ^[0-9]+$ ]] && launched_at="$_launched"
    _prompt="$(sed -n 's/^prompt=//p' "$state_file" | tail -1)"
    [[ -n "$_prompt" ]] && prompt_file_abs="$_prompt"
    _mode="$(sed -n 's/^mode=//p' "$state_file" | tail -1)"
    [[ -n "$_mode" ]] && mode_label="$_mode"
    _iso="$(sed -n 's/^iso=//p' "$state_file" | tail -1)"
    if [[ -n "$_iso" ]]; then
      iso="$_iso"
    else
      iso="prompt-only (resume: sidecar has no iso record)"
    fi
  else
    iso="prompt-only (resume: sidecar missing)"
  fi
else
  # The reviewer is handed a prompt INSIDE the run dir (RUN_ROOT is denied
  # read+write for every sandboxed run, with the staged copy re-allowed for
  # this run only). The source is MOVED into the run dir on first launch and
  # never read again from the world-writable tmp top level — a retry
  # re-uses the staged copy, so a sibling sandboxed run can no longer swap
  # the instruction file behind the documented retry.
  # Prompt handoff rule (1.1.20): a host-supplied source ALWAYS wins when it
  # exists and differs from the staged copy (unconditional republish — no
  # mtime test, which rename semantics made spoofable). Only when the host
  # supplies no source (pure retry/resume) is the already-staged run-internal
  # copy used, and the tmp-top-level path is never read then either.
  prompt_arg_abs=""
  if [[ -n "$prompt_file" ]]; then
    prompt_arg_abs="$(cd "$(dirname "$prompt_file")" 2>/dev/null && pwd -P)/$(basename "$prompt_file")"
  fi
  prompt_file_abs="$run_dir/prompt.md"
  if [[ -n "$prompt_arg_abs" && -s "$prompt_arg_abs" && "$prompt_arg_abs" != "$prompt_file_abs" ]]; then
    [[ -L "$prompt_arg_abs" ]] && die "refusing a symlinked --prompt-file: $prompt_arg_abs" 2
    mv -f "$prompt_arg_abs" "$prompt_file_abs" || die "cannot stage the prompt into the run dir" 2
    [[ -L "$prompt_file_abs" ]] && { rm -f "$prompt_file_abs"; die "staged prompt is a symlink; refusing" 2; }
    prompt_source_abs="$prompt_arg_abs"
  elif [[ -s "$prompt_file_abs" ]]; then
    # retry/resume with no host source: the staged copy is the only source
    prompt_source_abs="$prompt_file_abs"
  else
    die "prompt file missing or empty: ${prompt_file:-<none>} (write the review instruction file first; a staged copy at $prompt_file_abs would also be accepted)" 2
  fi

  # single-flight: atomic claim via noclobber — the pidfile is created WITH
  # content in one step so a concurrent loser can never observe an empty
  # claim. An empty/unparseable pidfile can never represent a live claim
  # (claims are always created with content), so it is stale: reclaim it via
  # the same atomic mv path instead of locking the rid forever.
  if ! ( set -o noclobber; printf '%s|%s\n' "$$" "$launched_at" >"$pid_file" ) 2>/dev/null; then
    old_pid="$(cut -d'|' -f1 "$pid_file" 2>/dev/null || true)"
    if [[ -n "$old_pid" && "$old_pid" =~ ^[0-9]+$ && "$old_pid" != 0 ]] && pid_alive "$old_pid"; then
      emit "CODE=7 REASON=already_running RID=$rid PID=$old_pid"
      exit 7
    fi
    # atomic stale reclaim: only one process can win the rename. The mv is
    # bound to the claim we probed — after moving, re-verify the moved file
    # still holds the same pid; if it does not, a newer live claim slipped in
    # (restore it and fail closed to CODE=7) instead of silently stealing it.
    stale_target="$pid_file.stale.$$"
    # Re-read immediately before the rename and only steal the pidfile while
    # it still holds the probed stale claim: a claim replaced under us is
    # LIVE, and renaming it away would hand the vacancy to a third launcher
    # (two omp processes for one rid). Residual: a claim swapped in within
    # the microseconds between this read and the mv (adjacent commands) is
    # still stealable — the post-mv mismatch check below keeps the
    # bookkeeping consistent and every path here fails closed to CODE=7
    # (best-effort single-flight; a mkdir-based lock would be airtight but
    # changes the documented pidfile contract).
    moved_pid="$(cut -d'|' -f1 "$pid_file" 2>/dev/null || true)"
    if [[ "$moved_pid" != "$old_pid" ]]; then
      emit "CODE=7 REASON=already_running RID=$rid PID=${moved_pid:-unknown}"
      exit 7
    fi
    if ! mv "$pid_file" "$stale_target" 2>/dev/null; then
      emit "CODE=7 REASON=already_running RID=$rid PID=unknown"
      exit 7
    fi
    moved_pid="$(cut -d'|' -f1 "$stale_target" 2>/dev/null || true)"
    if [[ "$moved_pid" != "$old_pid" ]]; then
      # Restore only into the vacancy: an unconditional rename-replace here
      # would clobber a live claim that won noclobber in the window since we
      # moved the pidfile away — two omp processes for one rid (the exact
      # invariant this branch exists to protect). When pid_file is present,
      # the surviving claim is authoritative either way: fail closed 7.
      [[ -e "$pid_file" ]] || mv "$stale_target" "$pid_file" 2>/dev/null
      rm -f "$stale_target"
      emit "CODE=7 REASON=already_running RID=$rid PID=${moved_pid:-unknown}"
      exit 7
    fi
    rm -f "$stale_target"
    if ! ( set -o noclobber; printf '%s|%s\n' "$$" "$launched_at" >"$pid_file" ) 2>/dev/null; then
      old_pid="$(cut -d'|' -f1 "$pid_file" 2>/dev/null || true)"
      emit "CODE=7 REASON=already_running RID=$rid PID=${old_pid:-unknown}"
      exit 7
    fi
  fi

  # overlay is generated for guarded AND no-tools modes: the reviewed repo's
  # .omp/hooks|tools|extensions load as code even without tools, so the
  # provider/extension strip must be active in every non-yolo mode
  generate_overlay "$bash_allow_extra" >"$overlay_file" || die "cannot write config overlay" 2
  if [[ "$no_tools" == true ]]; then
    omp_args=(--no-session --no-tools --no-lsp --no-rules --no-skills --no-extensions --max-time "$max_time" --config "$overlay_file" -p "@$prompt_file_abs")
  elif [[ "$yolo" == true ]]; then
    omp_args=(--no-session --max-time "$max_time" --approval-mode yolo -p "@$prompt_file_abs")
  else
    omp_args=(--no-session --max-time "$max_time" $(guarded_extra_flags) --config "$overlay_file" -p "@$prompt_file_abs")
  fi
  if [[ -n "$tools_list" ]]; then
    omp_args+=(--tools "$tools_list")
  fi
  if [[ -n "$model" ]]; then
    omp_args+=(--model "$model")
  fi

  # write-boundary: the bash allowlist is a string-prefix match and cannot
  # express "no file-writing options" (git's --output=<file> writes without
  # shell redirection — probed live). On macOS, wrap the omp process in a
  # sandbox-exec profile denying writes under the reviewed repo, its git
  # dir, this skill dir, AND the runner's own contract artifacts (result/
  # err/state/overlay/profile/prompt) — otherwise a steered reviewer could
  # forge the completion contract with `git diff --output=<result-file> HEAD`
  # (the rid is derivable from the DIFF_PATH in the prompt). Elsewhere
  # Guarded degrades to prompt-only. --yolo stays unwrapped by design
  # (documented UNRESTRICTED).
  launch_pre=()
  iso="prompt-only (sandbox-exec unavailable; boundary not enforcing)"
  if [[ "$(uname -s)" == "Darwin" ]] && sandbox_exec_path="$(command -v sandbox-exec 2>/dev/null)" && [[ "$yolo" != true ]]; then
    omp_skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
    git_dir="$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null || printf '%s/.git' "$repo")"
    [[ -L "$sandbox_profile_file" ]] && die "refusing to follow pre-existing symlink: $sandbox_profile_file" 2
    cat >"$sandbox_profile_file" <<'SANDBOX_PROFILE'
(version 1)
(allow default)
; write surface: deny the WHOLE home directory (git's --output= and plain
; redirection reach any user-writable path through the prefix allowlist).
; ~/.omp is deny-by-default. omp MUST write its runtime stores (agent.db,
; history.db, models.db + WAL/SHM — otherwise a sandboxed launch dies
; SQLITE_READONLY at store open, verified live), so those get re-allowed;
; config.yml (the persistent config-injection vector), sessions/ and
; terminal-sessions/ stay write-denied. agent/cache (LSP manifests) and
; puppeteer (browser bundle) are host-executed/consumed — NOT re-allowed.
(deny file-write* (subpath (param "HOME_DIR")))
(deny file-write* (subpath (param "OMP_HOME")))
(deny file-write* (subpath (param "WORKSPACE")))
(deny file-write* (subpath (param "GIT_DIR")))
(deny file-write* (subpath (param "GIT_COMMON_DIR")))
(deny file-write* (subpath (param "SKILL_DIR")))
(deny file-write* (literal (param "HOME_CANARY")))
(deny file-write* (literal (param "PROMPT_FILE")))
; RUN_ROOT: the shared parent of ALL runs' artifact dirs — denying it in every
; profile makes every run's result/state/prompt mutually unwritable (SBPL has
; no wildcards, so a per-rid deny could never express that)
(deny file-write* (subpath (param "RUN_ROOT")))
(allow file-write* (subpath (param "TMP_DIR")))
; non-HOME host surfaces: the toolchain prefix, system paths and the shared
; area are NOT writable by a sandboxed reviewer (omp itself lives under the
; Homebrew prefix, and the reviewer must not be able to modify it)
(deny file-write* (subpath "/opt/homebrew"))
(deny file-write* (subpath "/usr/local"))
(deny file-write* (subpath "/Library"))
(deny file-write* (subpath "/Users/Shared"))
(deny file-write* (subpath "/Applications"))
(deny file-write* (literal (param "OMP_BIN")))
; re-asserted AFTER the TMP_DIR allow: a reviewed toplevel or git dir staged
; under $TMPDIR must still be unwritable (the TMP allow would otherwise
; outrank the four denies above under last-match-wins)
(deny file-write* (subpath (param "WORKSPACE")))
(deny file-write* (subpath (param "GIT_DIR")))
(deny file-write* (subpath (param "GIT_COMMON_DIR")))
(deny file-write* (subpath (param "SKILL_DIR")))
; runtime re-allows come LAST among the write rules (before the config/artifact
; re-denies) so neither the TMP_DIR allow nor a reviewed toplevel containing
; ~/.omp (e.g. --repo $HOME) can void them — the omp store writes must win,
; or every sandboxed launch dies SQLITE_READONLY (residual, documented: the
; reviewer may write ~/.omp runtime stores when the toplevel contains them;
; config.yml/sessions/RUN_ROOT/probe literals stay denied below)
(allow file-write* (literal (param "OMP_AGENT_DB")))
(allow file-write* (literal (param "OMP_AGENT_DB_WAL")))
(allow file-write* (literal (param "OMP_AGENT_DB_SHM")))
(allow file-write* (literal (param "OMP_HISTORY_DB")))
(allow file-write* (literal (param "OMP_HISTORY_DB_WAL")))
(allow file-write* (literal (param "OMP_HISTORY_DB_SHM")))
(allow file-write* (literal (param "OMP_MODELS_DB")))
(allow file-write* (literal (param "OMP_MODELS_DB_WAL")))
(allow file-write* (literal (param "OMP_MODELS_DB_SHM")))
(allow file-write* (subpath (param "OMP_LOGS_DIR")))
(allow file-write* (subpath (param "OMP_RUN_DIR")))
(allow file-write* (literal (param "OMP_GPU_CACHE")))
(allow file-write* (literal (param "OMP_LAST_CHANGELOG")))
; config-injection vectors and the artifact tree are re-asserted LAST
(deny file-write* (literal (param "OMP_CONFIG")))
(deny file-write* (literal (param "OMP_CONFIG_LOCK")))
(deny file-write* (subpath (param "OMP_SESSIONS_DIR")))
(deny file-write* (subpath (param "OMP_TERMINAL_SESSIONS_DIR")))
(deny file-write* (subpath (param "RUN_ROOT")))
(deny file-write* (literal (param "PROMPT_FILE")))
; agent/cache (LSP-server manifests), puppeteer (installed browser bundle)
; and run/daemons broker state are host-executed/consumed — NOT re-allowed
; (residual: ~/.omp/run/<id>/broker.token is writable via the run/ re-allow)
; read surface: skill-home denies first (review targets may live under them),
; then the review-target re-allows, then EVERY secret deny LAST so a reviewed
; toplevel that contains a credential store cannot void the deny
(deny file-read* (subpath (param "CODEX_DIR")))
(deny file-read* (subpath (param "CLAUDE_DIR")))
(deny file-read* (subpath (param "AGENTS_SKILLS_DIR")))
(allow file-read* (subpath (param "WORKSPACE")))
(allow file-read* (subpath (param "GIT_DIR")))
(allow file-read* (subpath (param "SKILL_DIR")))
(deny file-read* (subpath (param "SSH_DIR")))
(deny file-read* (subpath (param "AWS_DIR")))
(deny file-read* (subpath (param "GNUPG_DIR")))
(deny file-read* (subpath (param "GH_CONFIG_DIR")))
(deny file-read* (subpath (param "KUBE_DIR")))
(deny file-read* (subpath (param "DOCKER_DIR")))
(deny file-read* (subpath (param "AZURE_DIR")))
(deny file-read* (subpath (param "GCLOUD_DIR")))
(deny file-read* (subpath (param "TERRAFORM_DIR")))
(deny file-read* (literal (param "GIT_CREDENTIALS_FILE")))
(deny file-read* (literal (param "GIT_XDG_CREDENTIALS")))
(deny file-read* (literal (param "YARNRC_FILE")))
(deny file-read* (literal (param "NETRC_FILE")))
(deny file-read* (literal (param "NPMRC_FILE")))
(deny file-read* (literal (param "PYPRC_FILE")))
(deny file-read* (subpath (param "PIP_CONFIG_DIR")))
(deny file-read* (literal (param "PIP_LEGACY_FILE")))
(deny file-read* (subpath (param "BUNDLE_DIR")))
(deny file-read* (literal (param "GEM_CREDENTIALS_FILE")))
(deny file-read* (literal (param "M2_SETTINGS_FILE")))
(deny file-read* (literal (param "GRADLE_PROPERTIES_FILE")))
(deny file-read* (literal (param "CARGO_CREDENTIALS_FILE")))
(deny file-read* (literal (param "COMPOSER_AUTH_FILE")))
(deny file-read* (subpath (param "RUN_ROOT")))
; the reviewer must still read its own config overlay AND the staged prompt
; (omp resolves `-p @file` in-process after the profile applies; an
; unreadable file is a hard error) — re-allowed after the RUN_ROOT deny,
; while result/state siblings stay read-denied
(allow file-read* (literal (param "OVERLAY_FILE")))
(allow file-read* (literal (param "STAGED_PROMPT")))
; note: the exported diff lives under GIT_DIR/review-cache and stays
; readable through the GIT_DIR re-allow — no separate DIFF_FILE rule
SANDBOX_PROFILE
    git_common_dir="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || printf '%s' "$git_dir")"
    repo_toplevel="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$repo")"
    # SBPL matches kernel-resolved paths — every path param (git dirs and all
    # credential stores) must be canonicalized or the rule is silently inert
    # (a symlinked ~/.ssh or a symlinked .git otherwise voids its deny)
    canary_dir="$(mktemp -d "$run_dir/.canary.XXXXXX")" || die "cannot create canary dir" 2
    home_canary="$HOME/.omp-review-write-canary.$$.$RANDOM"
    rp() { /usr/bin/perl -MCwd=realpath -e 'print(realpath($ARGV[0]) // $ARGV[0])' "$1" 2>/dev/null || printf '%s' "$1"; }

# canonicalization availability: without a usable perl the realpath step
# falls back to raw spellings, which SBPL treats as inert — surface it
# instead of silently reverting to the pre-fix behaviour
    canon_unavailable=0
    [[ -x /usr/bin/perl ]] || canon_unavailable=1
    canon_note=""
    [[ "$canon_unavailable" == 1 ]] && canon_note="; WARNING path canonicalization unavailable (perl missing): symlink-sensitive denies may be inert"
    git_dir="$(rp "$git_dir")"
    git_common_dir="$(rp "$git_common_dir")"
    omp_bin_real="$(rp "$omp_bin")"
    cred_d_args=()
    while IFS='=' read -r _k _v; do
      cred_d_args+=(-D "$_k=$(rp "$_v")")
    done <<CRED_PATHS
WORKSPACE=$repo_toplevel
GIT_DIR=$git_dir
GIT_COMMON_DIR=$git_common_dir
SKILL_DIR=$omp_skill_dir
HOME_DIR=$HOME
OMP_HOME=$HOME/.omp
OMP_AGENT_DB=$HOME/.omp/agent/agent.db
OMP_AGENT_DB_WAL=$HOME/.omp/agent/agent.db-wal
OMP_AGENT_DB_SHM=$HOME/.omp/agent/agent.db-shm
OMP_HISTORY_DB=$HOME/.omp/agent/history.db
OMP_HISTORY_DB_WAL=$HOME/.omp/agent/history.db-wal
OMP_HISTORY_DB_SHM=$HOME/.omp/agent/history.db-shm
OMP_MODELS_DB=$HOME/.omp/agent/models.db
OMP_MODELS_DB_WAL=$HOME/.omp/agent/models.db-wal
OMP_MODELS_DB_SHM=$HOME/.omp/agent/models.db-shm
OMP_CONFIG=$HOME/.omp/agent/config.yml
OMP_CONFIG_LOCK=$HOME/.omp/agent/config.yml.lock
OMP_SESSIONS_DIR=$HOME/.omp/agent/sessions
OMP_TERMINAL_SESSIONS_DIR=$HOME/.omp/agent/terminal-sessions
OMP_GPU_CACHE=$HOME/.omp/gpu_cache.json
OMP_LAST_CHANGELOG=$HOME/.omp/agent/last-changelog-version
OMP_LOGS_DIR=$HOME/.omp/logs
OMP_RUN_DIR=$HOME/.omp/run
TMP_DIR=$tmp_dir
RUN_ROOT=$run_root
HOME_CANARY=$home_canary
OVERLAY_FILE=$overlay_file
OMP_BIN=$omp_bin_real
SSH_DIR=$HOME/.ssh
AWS_DIR=$HOME/.aws
GNUPG_DIR=$HOME/.gnupg
GH_CONFIG_DIR=$HOME/.config/gh
CODEX_DIR=$HOME/.codex
KUBE_DIR=$HOME/.kube
DOCKER_DIR=$HOME/.docker
AZURE_DIR=$HOME/.azure
GCLOUD_DIR=$HOME/.config/gcloud
CLAUDE_DIR=$HOME/.claude
AGENTS_SKILLS_DIR=$HOME/.agents
TERRAFORM_DIR=$HOME/.terraform.d
GIT_CREDENTIALS_FILE=$HOME/.git-credentials
GIT_XDG_CREDENTIALS=$HOME/.config/git/credentials
YARNRC_FILE=$HOME/.yarnrc.yml
NETRC_FILE=$HOME/.netrc
NPMRC_FILE=$HOME/.npmrc
PYPRC_FILE=$HOME/.pypirc
PIP_CONFIG_DIR=$HOME/.config/pip
PIP_LEGACY_FILE=$HOME/.pip/pip.conf
BUNDLE_DIR=$HOME/.bundle
GEM_CREDENTIALS_FILE=$HOME/.gem/credentials
M2_SETTINGS_FILE=$HOME/.m2/settings.xml
GRADLE_PROPERTIES_FILE=$HOME/.gradle/gradle.properties
CARGO_CREDENTIALS_FILE=$HOME/.cargo/credentials.toml
COMPOSER_AUTH_FILE=$HOME/.composer/auth.json
CRED_PATHS
    launch_pre=("$sandbox_exec_path" "${cred_d_args[@]}" -D "PROMPT_FILE=$prompt_source_abs" -D "STAGED_PROMPT=$run_dir/prompt.md" -f "$sandbox_profile_file")
    # usability + enforcement canaries: some hosts deny sandbox_apply at the
    # process level (observed on WorkBuddy 2026-09-22), and an applied
    # sandbox is only trustworthy if its denies actually fire AND its
    # re-allows keep the reviewer sighted AND omp itself still starts. Every
    # canary probes run against runner-created paths; the workspace
    # write-deny probe creates a mktemp -d INSIDE the reviewed toplevel and
    # removes it within the probe window (SIGINT/SIGTERM in that window can
    # leave the empty dir — the trap below also clears it).
    canary_ok=true
    canary_fail=""
    _wsc=""
    # a host timeout/Ctrl-C inside the in-repo probe window must not leave the
    # probe dir behind in the user's checkout
    trap '[[ -n "${_wsc:-}" ]] && rm -rf "$_wsc" 2>/dev/null' EXIT INT TERM
    # macOS mktemp replaces TRAILING Xs only — the template must end in Xs
    # (a `.log` suffix would survive literally and, worse, collide with the
    # leftover of a failed previous run under O_EXCL). Fall back, and log
    # only when a real path exists.
    rm -f "$tmp_dir/omp-review-$rid-canary-fail."* 2>/dev/null
    canary_log="$(mktemp "$run_dir/canary-fail.XXXXXX" 2>/dev/null)" || canary_log=""
    record_canary_fail() { # name [reason-file]
      canary_fail="$1"
      [[ -n "$canary_log" ]] || return 0
      local _rf="${2:-}"
      printf 'canary %s failed\n' "$1" >>"$canary_log"
      if [[ -n "$_rf" && -s "$_rf" ]]; then
        printf 'stderr:\n%s\n' "$(cat "$_rf" 2>/dev/null)" >>"$canary_log"
      fi
    }
    if ! "${launch_pre[@]}" /usr/bin/true >"$canary_dir/apply.out" 2>"$canary_dir/apply.err"; then
      record_canary_fail sandbox_apply "$canary_dir/apply.err"
      canary_ok=false
    fi
    if [[ "$canary_ok" == true ]]; then
      # write-deny canary: HOME writes are denied -> must fail. The probe
      # path is unpredictable (pid+random, added to the profile as a literal
      # deny) so a planted symlink at a fixed name cannot receive the append.
      if "${launch_pre[@]}" /bin/sh -c 'echo x >> "$1"' _ "$home_canary" >"$canary_dir/home_write.out" 2>"$canary_dir/home_write.err"; then
        record_canary_fail home_write_deny "$canary_dir/home_write.err"
        canary_ok=false
      fi
      rm -f "$home_canary" 2>/dev/null
    fi
    if [[ "$canary_ok" == true ]]; then
      # write-deny canary: repo/WORKSPACE writes are denied -> must fail.
      # Probed with a runner-created mktemp -d inside the reviewed toplevel
      # (removed after the probe) so the WORKSPACE rule itself is exercised;
      # if the toplevel is not writable for the runner, the runner-owned
      # CANARY_DIR probe covers the same SBPL mechanism and the ISO marks
      # the target rule as inferred.
      ws_probed=false
      _wsc="$(mktemp -d "$repo_toplevel/.omp-review-canary.XXXXXX" 2>/dev/null)"
      if [[ -n "$_wsc" ]]; then
        ws_probed=true
        if "${launch_pre[@]}" /bin/sh -c 'echo x >> "$1"' _ "$_wsc/probe" >"$canary_dir/ws_write.out" 2>"$canary_dir/ws_write.err"; then
          record_canary_fail workspace_write_deny "$canary_dir/ws_write.err"
          canary_ok=false
        fi
        rm -rf "$_wsc"; _wsc=""
      else
        if "${launch_pre[@]}" /bin/sh -c 'echo x >> "$1"' _ "$canary_dir/probe" >"$canary_dir/ws_write.out" 2>"$canary_dir/ws_write.err"; then
          record_canary_fail workspace_write_deny "$canary_dir/ws_write.err"
          canary_ok=false
        fi
      fi
    fi
    if [[ "$canary_ok" == true ]]; then
      # write-deny canary: contract artifacts are denied -> must fail
      if "${launch_pre[@]}" /bin/sh -c 'echo x >> "$1"' _ "$result_file" >"$canary_dir/artifact_write.out" 2>"$canary_dir/artifact_write.err"; then
        record_canary_fail artifact_write_deny "$canary_dir/artifact_write.err"
        canary_ok=false
      fi
    fi
    if [[ "$canary_ok" == true ]]; then
      # read-deny canary: probe the FIRST EXISTING credential path (the deny
      # must fail the read). On hosts with none of them, the boundary is
      # unprobed — surface that in the ISO instead of claiming verified.
      # Keep in lockstep with the SANDBOX_PROFILE credential read-denies:
      # one candidate per deny rule (23 = 23); a rule without a candidate is
      # a deny the canary can never verify.
      cred_probe=""
      for _cd in "$HOME/.ssh" "$HOME/.gnupg" "$HOME/.aws" "$HOME/.config/gh" "$HOME/.kube" "$HOME/.config/gcloud" \
                   "$HOME/.docker" "$HOME/.azure" "$HOME/.terraform.d" "$HOME/.git-credentials" "$HOME/.config/git/credentials" \
                   "$HOME/.yarnrc.yml" "$HOME/.netrc" "$HOME/.npmrc" "$HOME/.pypirc" "$HOME/.config/pip" \
                   "$HOME/.pip/pip.conf" "$HOME/.bundle" "$HOME/.gem/credentials" "$HOME/.m2/settings.xml" \
                   "$HOME/.gradle/gradle.properties" "$HOME/.cargo/credentials.toml" "$HOME/.composer/auth.json"; do
        [[ -e "$_cd" ]] && { cred_probe="$_cd"; break; }
      done
      if [[ -n "$cred_probe" ]]; then
        if "${launch_pre[@]}" /bin/sh -c 'ls "$1"' _ "$cred_probe" >/dev/null 2>"$canary_dir/cred_read.err"; then
          record_canary_fail credential_read_deny "$canary_dir/cred_read.err"
          canary_ok=false
        fi
      fi
    fi
    if [[ "$canary_ok" == true ]]; then
      # detach-chain canary: the REAL launch chain (perl setsid -> sandbox ->
      # omp) must work — a message-less 126/127 exit from the setsid wrapper
      # would otherwise surface later as a misdiagnosed omp crash
      if ! /usr/bin/perl -e 'use POSIX qw(setsid); setsid() != -1 or die "setsid failed: $!\n"; exec @ARGV or die "exec failed: $!\n"' -- "${launch_pre[@]}" /usr/bin/true >/dev/null 2>"$canary_dir/detach.err"; then
        record_canary_fail detach_chain "$canary_dir/detach.err"
        canary_ok=false
      fi
    fi
    if [[ "$canary_ok" == true ]]; then
      # overlay-read canary: the reviewer must be able to read its own
      # --config overlay (omp treats an unreadable overlay as a hard error)
      if ! "${launch_pre[@]}" /bin/sh -c 'cat "$1" >/dev/null' _ "$overlay_file" >"$canary_dir/overlay_read.out" 2>"$canary_dir/overlay_read.err"; then
        record_canary_fail overlay_read_allow "$canary_dir/overlay_read.err"
        canary_ok=false
      fi
    fi
    if [[ "$canary_ok" == true ]]; then
      # staged-prompt read canary: the reviewer must be able to read the
      # prompt copy handed to -p @ (mirrors the overlay-read probe)
      if ! "${launch_pre[@]}" /bin/sh -c 'cat "$1" >/dev/null' _ "$run_dir/prompt.md" >"$canary_dir/prompt_read.out" 2>"$canary_dir/prompt_read.err"; then
        record_canary_fail prompt_read_allow "$canary_dir/prompt_read.err"
        canary_ok=false
      fi
    fi
    if [[ "$canary_ok" == true ]]; then
      # liveness + overlay canary: omp must start under the profile AND the
      # generated overlay must parse (a YAML typo would otherwise kill every
      # Guarded launch at runtime). NOTE: --version exits before omp opens
      # its runtime stores, so a SQLITE_READONLY at store open is NOT caught
      # here; the launch tail maps that error signature explicitly.
      if ! "${launch_pre[@]}" "$omp_bin" --config "$overlay_file" --version >"$canary_dir/liveness.out" 2>"$canary_dir/liveness.err"; then
        record_canary_fail omp_liveness_overlay "$canary_dir/liveness.err"
        canary_ok=false
      fi
    fi
    if [[ "$canary_ok" == true ]]; then
      # read-allow canary: the reviewer must stay sighted on the workspace
      if ! "${launch_pre[@]}" /bin/sh -c 'cat "$1/a.txt" >/dev/null 2>&1 || cat "$1/README.md" >/dev/null 2>&1 || ls "$1" >/dev/null' _ "$repo" >"$canary_dir/ws_read.out" 2>"$canary_dir/ws_read.err"; then
        record_canary_fail workspace_read_allow "$canary_dir/ws_read.err"
        canary_ok=false
      fi
    fi
    rm -rf "$canary_dir"
    # release the INT/TERM handlers — a trap without exit would otherwise
    # stop the runner honouring host cancellation for the rest of the run
    # (the EXIT handler stays: _wsc is already cleared)
    trap - INT TERM
    if [[ "$canary_ok" == true ]]; then
      rm -f "$canary_log"
      _ws="workspace write deny probed"
      [[ "$ws_probed" == true ]] || _ws="workspace write deny inferred (CANARY_DIR probe)"
      if [[ -n "$cred_probe" ]]; then
        iso="sandbox-exec (HOME-wide write deny + credential read deny + contract-artifact deny + overlay read allow, canary-verified; omp liveness verified; $_ws; selected credential reads only — not a general secrets or network boundary${canon_note})"
      else
        iso="sandbox-exec (HOME-wide write deny + contract-artifact deny, canary-verified; omp liveness verified; credential read deny unprobed: none of the probed credential paths exist; $_ws; not a general secrets or network boundary)"
      fi
    else
      launch_pre=()
      if [[ -n "$canary_log" ]]; then
        iso="prompt-only (sandbox-exec unavailable or boundary not enforcing; failed canary: ${canary_fail:-unknown}; details: $canary_log)"
      else
        iso="prompt-only (sandbox-exec unavailable or boundary not enforcing; failed canary: ${canary_fail:-unknown})"
      fi
    fi
  elif [[ "$yolo" == true ]]; then
    iso="prompt-only (yolo)"
  fi

  # launch: background process, stdout->result, stderr->err, cwd=repo.
  # setsid detaches omp into its own session/process group: when the host
  # reclaims the runner's process group at CODE=4 (observed on WorkBuddy
  # 2026-09-22 — every omp beyond the 540s wait budget was killed with the
  # runner), the detached review keeps running and the documented
  # CODE=4 -> --resume flow actually finds it alive.
  # setsid wraps sandbox-exec: profile -> omp, detached into its own session.
  # macOS setsid() returns the new session id on success and -1 on failure
  # (NOT 0) — a `== 0` check would misjudge every success as failure.
  # A setsid() failure dies WITH a message into ERRFILE (perl die exits
  # non-zero, typically 1 — the EXITED= value is not a fixed 126).
  # launch-time ownership re-verification: the stale-reclaim path is
  # best-effort (a µs window can displace and destroy a live claim while a
  # third launcher takes the vacancy), so a claimant whose pidfile entry no
  # longer holds its own claim must NOT exec omp — two reviews for one rid
  # would write the same result.md. Fail closed to CODE=7; the surviving
  # pidfile claim stays authoritative.
  claim_now="$(cat "$pid_file" 2>/dev/null || true)"
  if [[ "$claim_now" != "$$|$launched_at" ]]; then
    holder="$(cut -d'|' -f1 <<<"$claim_now")"
    [[ -n "$holder" ]] || holder="?"
    emit "CODE=7 REASON=lost-claim RID=$rid PID=$holder"
    exit 7
  fi
  ( cd "$repo" && exec /usr/bin/perl -e 'use POSIX qw(setsid); setsid() != -1 or die "setsid failed: $!\n"; exec @ARGV or die "exec failed: $!\n"' -- ${launch_pre[@]+"${launch_pre[@]}"} "$omp_bin" "${omp_args[@]}" ) >"$result_file" 2>"$err_file" &
  opid=$!
  # owner update via atomic replace — mktemp (O_EXCL) avoids both the
  # never-empty violation and any symlink-following on a sibling path
  _pid_tmp="$(mktemp "$pid_file.tmp.XXXXXX")" || die "cannot create pidfile temp" 2
  printf '%s|%s\n' "$opid" "$launched_at" >"$_pid_tmp" && mv "$_pid_tmp" "$pid_file"
  printf 'repo=%s\nref=%s\ntag=%s\nmax_time=%s\nmode=%s\nlaunched=%s\nprompt=%s\niso=%s\n' \
    "$repo" "$ref" "$tag" "$max_time" "$mode_label" "$launched_at" "$prompt_source_abs" "$iso" >"$state_file"
  emit "LAUNCHED RID=$rid PID=$opid OMPV=$omp_version MODE=$mode_label ISO=$iso"
fi

# ---------- bounded event-driven wait ----------

exited_label="?"
if [[ "$wait_needed" == true ]]; then
  if [[ "$wait_seconds" -eq 0 ]]; then
    # unlimited wait: poll until the process ends (bounded above by omp's own
    # --max-time). For background-task hosts: run the runner in the background
    # with --wait-seconds 0 and read the status line on completion — the
    # runner stays alive for the whole review, so process-group reclamation
    # (observed on WorkBuddy 2026-09-22) can never orphan omp.
    while pid_alive "$opid"; do
      sleep 5
    done
  else
    deadline=$(( $(date +%s) + wait_seconds ))
    while :; do
      if ! pid_alive "$opid"; then
        break
      fi
      if (( $(date +%s) >= deadline )); then
        # the sandbox profile is no longer needed once the launch is handed off
        # to the resume flow (kept private by umask 077, paths only — but do not
        # litter the documented CODE=4 flow)
        [[ -n "$sandbox_profile_file" ]] && rm -f "$sandbox_profile_file"
        emit "CODE=4 ELAPSED=$(( $(date +%s) - launched_at ))s RID=$rid PID=$opid"
        exit 4
      fi
      sleep 5
    done
  fi
  # launch mode: the runner is the parent, so capture the real exit status;
  # resume mode: the child was reparented, report unknown
  if [[ "$mode" == "launch" ]]; then
    wait "$opid" 2>/dev/null
    exited_label=$?
  fi
fi

# ---------- completion contract ----------

elapsed=$(( $(date +%s) - launched_at ))
classify_result "$result_file"; rc=$?
verdict="$(extract_verdict "$result_file")"
[[ -n "$verdict" ]] || verdict="?"
# claim-scoped cleanup: only remove bookkeeping this invocation still owns
# (a newer run for the same rid may have legitimately taken over). The prompt
# is NOT removed here — CODE=3/5 retry reuses it (documented retry policy).
# The state sidecar is PRESERVED (renamed next to the result) so the effective
# isolation level (iso=) stays attributable after a completed run.
if [[ -f "$pid_file" && "$(cat "$pid_file" 2>/dev/null)" == "$opid|$launched_at" ]]; then
  rm -f "$pid_file" "$overlay_file"
  [[ -f "$state_file" ]] && mv "$state_file" "$result_file.state"
fi
[[ -n "$sandbox_profile_file" ]] && rm -f "$sandbox_profile_file"
if [[ $rc -eq 0 ]]; then
  # The runner never removes a host-supplied prompt (1.1.19): the staged copy
  # lives in the run dir (retained for provenance) and the source is either
  # already moved in or a host-owned file the runner must not touch.
  :
  emit "CODE=0 EXITED=$exited_label RESULT=$(wc -c <"$result_file" | tr -d ' ') ELAPSED=${elapsed}s RID=$rid PID=$opid OMPV=$omp_version MODE=$mode_label VERDICT=$verdict RESULTFILE=$result_file ERRFILE=$err_file ISO=$iso"
  exit 0
elif [[ $rc -eq 3 ]]; then
  # a sandboxed launch whose profile denies a store omp must write dies
  # SQLITE_READONLY before producing output — deterministic, NOT transient;
  # a distinct REASON stops hosts from retry-looping the documented remedy
  if [[ "$iso" == sandbox-exec* ]] && grep -qiE 'SQLITE_READONLY|readonly database' "$err_file" 2>/dev/null; then
    emit "CODE=3 REASON=sandbox_profile_incompatible ELAPSED=${elapsed}s RID=$rid PID=$opid EXITED=$exited_label MODE=$mode_label RESULTFILE=$result_file ERRFILE=$err_file ISO=$iso"
  else
    emit "CODE=3 REASON=empty_result ELAPSED=${elapsed}s RID=$rid PID=$opid EXITED=$exited_label MODE=$mode_label RESULTFILE=$result_file ERRFILE=$err_file ISO=$iso"
  fi
  exit 3
else
  emit "CODE=5 REASON=no_verdict ELAPSED=${elapsed}s RID=$rid PID=$opid EXITED=$exited_label MODE=$mode_label RESULTFILE=$result_file ERRFILE=$err_file ISO=$iso"
  exit 5
fi
