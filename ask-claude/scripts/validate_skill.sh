#!/usr/bin/env bash
set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
skill_dir="$(cd "$script_dir/.." && pwd -P)"
skill_file="$skill_dir/SKILL.md"
runner="$script_dir/run_review.sh"
tests="$script_dir/test_run_review.sh"
failures=0

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

require_file() {
  local path="$1" label="$2"
  if [[ -f "$path" ]]; then
    pass "$label"
  else
    fail "$label (missing $path)"
  fi
}

require_executable() {
  local path="$1" label="$2"
  if [[ -x "$path" ]]; then
    pass "$label"
  else
    fail "$label (not executable: $path)"
  fi
}

require_literal() {
  local pattern="$1" path="$2" label="$3"
  if /usr/bin/grep -aFq -- "$pattern" "$path"; then
    pass "$label"
  else
    fail "$label (missing '$pattern' in $path)"
  fi
}

require_file "$skill_file" "SKILL.md exists"
require_file "$runner" "review runner exists"
require_file "$tests" "runner regression suite exists"

if [[ -f "$skill_file" ]]; then
  first_line="$(sed -n '1p' "$skill_file")"
  closing_line="$(awk 'NR > 1 {line=$0; sub(/\r$/, "", line); if (line ~ /^[[:space:]]*---[[:space:]]*$/) {print NR; exit}}' "$skill_file")"
  first_line="$(printf '%s' "$first_line" | sed 's/\r$//; s/[[:space:]]*$//')"
  [[ "$first_line" == "---" && -n "$closing_line" ]] && pass "YAML frontmatter is delimited" || fail "YAML frontmatter is delimited"

  frontmatter="$(sed -n "2,$((closing_line - 1))p" "$skill_file" 2>/dev/null || true)"
  [[ "$frontmatter" == *$'name: ask-claude'* ]] && pass "skill name is ask-claude" || fail "skill name is ask-claude"
  if printf '%s\n' "$frontmatter" | /usr/bin/grep -aEq '^description:[[:space:]]+Use when'; then
    pass "description is a trigger-only Use when statement"
  else
    fail "description is a trigger-only Use when statement"
  fi

  for section in \
    '## Ordinary Consultation' \
    '## Code Review' \
    '## Process Lifecycle' \
    '## Completion Contract' \
    '## Artifact Layout' \
    '## Failure Handling' \
    '## Maintenance Verification'
  do
    require_literal "$section" "$skill_file" "required section: ${section#\#\# }"
  done
fi

for executable in "$runner" "$tests" "$script_dir/validate_skill.sh"; do
  require_executable "$executable" "$(basename "$executable") is executable"
  if [[ -f "$executable" ]] && bash -n "$executable"; then
    pass "$(basename "$executable") has valid Bash syntax"
  else
    fail "$(basename "$executable") has valid Bash syntax"
  fi
done

if [[ -f "$runner" ]]; then
  require_literal 'default_timeout="30m"' "$runner" "runner default timeout is 30 minutes"
  require_literal '--dangerously-skip-permissions' "$runner" "review prevents permission stalls"
  require_literal '--output-format json' "$runner" "review uses print-mode JSON"
  require_literal '--json-schema' "$runner" "review requests structured output"
  require_literal '--safe-mode' "$runner" "review disables repo/user Claude customizations by default"
  require_literal '--no-safe-mode' "$runner" "trusted-repo customization opt-out exists"
  require_literal '--tools ""' "$runner" "runner offers the tools-off untrusted-repo mode"
  require_literal 'execution_record_write_failure' "$runner" "final execution record write fails closed"
  require_literal 'outer_timeout_kill_after' "$runner" "timeout kill-after is distinguished from provider failure"
  require_literal 'dependency_pgrep_missing' "$runner" "process tracking dependencies fail closed"
  require_literal 'process_tracking_degraded' "$runner" "runtime process tracking degradation fails closed"
  require_literal 'tool_usage_parse_failure' "$runner" "debug tool parsing fails closed"
  require_literal 'publish_artifact_file' "$runner" "artifact publication revalidates its path"
  require_literal 'sidecar_dir_is_safe' "$runner" "sidecar publication revalidates its directory"
  require_literal 'sidecar_file_is_safe' "$runner" "sidecar targets require regular files"
  require_literal 'sidecar_path_unsafe' "$runner" "unsafe sidecar path fails closed"
  require_literal 'preflight_failure_reason' "$runner" "preflight artifact publication preserves original reason"
  require_literal 'artifact must remain inside repository worktree' "$runner" "artifact path is repository bounded"

  # version parity: SKILL.md frontmatter == runner_version == newest changelog
  # heading (runtime attribution drifted once before — changelog 1.6.2)
  skill_version="$(sed -n '2,/^---$/p' "$skill_file" | sed -n 's/^[[:space:]]*version:[[:space:]]*//p' | head -1 | tr -d '[:space:]')"
  runner_version_declared="$(sed -n 's/^runner_version="\([^"]*\)".*/\1/p' "$runner" | head -1)"
  newest_changelog_version="$(sed -n 's/^## \([0-9][0-9.]*\) — .*/\1/p' "$skill_dir/CHANGELOG.md" 2>/dev/null | head -1)"
  if [[ -n "$skill_version" && "$skill_version" == "$runner_version_declared" && "$skill_version" == "$newest_changelog_version" ]]; then
    pass "SKILL, runner, and changelog versions agree ($skill_version)"
  else
    fail "version parity broken: SKILL=${skill_version:-none} runner=${runner_version_declared:-none} changelog=${newest_changelog_version:-none}"
  fi
  if /usr/bin/grep -aEq -- '--max-budget-usd|claude[[:space:]]+ultrareview' "$runner"; then
    fail "runner excludes forbidden budget and ultrareview modes"
  else
    pass "runner excludes forbidden budget and ultrareview modes"
  fi
fi

credential_pattern='(ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|OPENAI_API_KEY|DEEPSEEK_API_KEY|AWS_SECRET_ACCESS_KEY)[[:space:]]*[:=][[:space:]]*["'\''`]?[A-Za-z0-9._~+/-]{12,}'
credential_found=false
for path in "$skill_file" "$runner" "$script_dir/validate_skill.sh"; do
  if [[ -f "$path" ]] && LC_ALL=C /usr/bin/grep -aEiq -- "$credential_pattern" "$path"; then
    fail "embedded credential pattern found in $path"
    credential_found=true
  fi
done
[[ "$credential_found" == true ]] || pass "no embedded credential assignments found"

if [[ "$failures" -ne 0 ]]; then
  printf '%s validation check(s) failed.\n' "$failures" >&2
  exit 1
fi

printf 'ask-claude skill validation passed.\n'
