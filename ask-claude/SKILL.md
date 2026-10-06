---
name: ask-claude
version: 1.7.3
description: Use when requesting a focused consultation, code review, commit review, or external second opinion through the local Claude Code CLI
---

# Ask Claude (Local CLI)

Use the locally installed Claude Code CLI as an external advisor. Run it directly; do not route through MCP.

This skill is agent-neutral: it locates its own scripts relative to this SKILL.md file, so it works from any skills directory (for example `~/.agents/skills`, `~/.codex/skills`, or a symlinked agent home) that satisfies the Host Compatibility Notes below. When referencing the bundled scripts from an arbitrary host agent, resolve the skill directory from the loaded skill file path instead of assuming a fixed home.

**Naming** (deliberate, do not "fix"): the skill is `ask-claude` — without the `-review` suffix — because it covers general consultation as well as code review. The `-review` suffix on the sibling runners (`ask-omp-review`, `ask-kimi-review`) marks review-only scope; it is a scope boundary, not a naming inconsistency. (The Windows port lineage is separately named `ask-claude-review`.)

## Host Compatibility Notes

Absorbed from the Windows port (`ask-claude-review`, cross-host design):

1. **Process-tracking prerequisites**: the runner needs `ps`/`pgrep` for process tracking. Hosts whose command sandbox denies `ps` fail closed at preflight with `dependency_ps_unusable` — this is by design. Observed on WorkBuddy (2026-09-21): its Bash tool denies `ps` even with the per-call sandbox disabled (the restriction sits at the host process level), so the full runner cannot execute from inside WorkBuddy. From inside such hosts, use Ordinary Consultation mode only; run the full runner from a terminal or an unrestricted host.
2. **Host command timeout vs runner timeout**: host command-execution tools often default to ~120s with a ~600s cap (TRAE `RunCommand`, Claude Code `Bash`, WorkBuddy `Bash`; omp uses `timeout_seconds`, default 600s), while the runner's own outer timeout is 30 minutes. Set the host-side tool timeout to its maximum, and run long reviews as a background task with completion notification, or expect the host call to return before the review finishes and poll the artifact/sidecar instead. Never judge completion from host-call silence — intermediate silence is neither success nor failure evidence.
3. **Concurrent invocations**: the runner does not coordinate multiple host sessions (artifact names use timestamp + PID). Avoid two reviews of the same repo and scope at the same time, or separate them with distinct `--slug` / `--artifact` paths. (The Windows port's deterministic run-id single-flight protection is a candidate future feature.)
4. **Symlink the skill directory, not individual files**: the self-location logic resolves through a symlinked directory (`cd` + `pwd -P`), but a symlink placed on the script file itself would resolve `dirname(BASH_SOURCE)` to the wrong tree. Deploy by directory symlink (or a full copy), never by linking `run_review.sh` alone.

## Ordinary Consultation

Use print mode with tools disabled, safe mode on, no Chrome integration, no session persistence, and structured JSON. `--safe-mode` is what keeps the consulted repository's own hooks, MCP servers, and CLAUDE.md from executing in or steering the consultant — keep it on whenever the working directory is not a repository you own:

```bash
claude -p --tools "" --safe-mode --no-session-persistence --no-chrome --output-format json "<task>"
```

Only for a trusted repository that legitimately requires its own configuration, omit `--safe-mode` (the CLI has no negation flag; `--no-safe-mode` exists only as the bundled runner's opt-out):

```bash
claude -p --tools "" --no-session-persistence --no-chrome --output-format json "<task>"
```

Use `--fallback-model <models>` only when a fallback is requested or the primary model is unavailable. Never add `--max-budget-usd` and never invoke `claude ultrareview` from this skill.

## Code Review

All code, commit, pull request, staged, or working-tree reviews must use the bundled runner. Do not copy a shortened raw `claude` command from this file.

```bash
# Resolve the skill directory from this SKILL.md location (works from any agent home).
runner="$(cd "$(dirname "<path-to-this-SKILL.md>")/scripts" && pwd -P)/run_review.sh"
# Example when installed at ~/.agents/skills/ask-claude:
# runner="$HOME/.agents/skills/ask-claude/scripts/run_review.sh"
"$runner" \
  --scope 'HEAD~2..HEAD' \
  --task 'Review the requested commits for correctness and regressions' \
  --slug 'recent-commits'
```

The runner enforces these approved defaults:

- `claude -p` with `--output-format json` and `--json-schema`.
- `--dangerously-skip-permissions` so permission prompts cannot stall review.
- `--safe-mode` by default (all custom Claude configuration — project and user CLAUDE.md, skills, plugins, hooks, MCP servers, custom commands and agents — disabled, so the reviewed repository's `.claude/settings.json` hooks, `.mcp.json` servers, and `CLAUDE.md` cannot execute or steer the reviewer). Use `--no-safe-mode` only for a trusted repository that legitimately requires its own configuration; the artifact and `execution.json` record the choice.
- `--no-chrome` and, in normal mode, `--no-session-persistence`.
- `--disallowedTools "Edit,Write,NotebookEdit,WebSearch,WebFetch"` (the web tools are disabled to close the read-tier egress path), plus a macOS sandbox that denies provider-process writes to the repository, Git directory, and skill directory and re-denies Claude Code's code-bearing config surfaces (settings/hooks/commands/agents/skills/plugins). Bash remains available for read-only repository inspection. This is not a general secrets or network-isolation boundary.
- `--no-tools` mode for untrusted or archived repositories: forwards `--tools ""` so nothing the reviewed repo ships can steer an auto-approved capability. The reviewer then sees only the task and scope text (the prompt tells it to return `BLOCKED` when the material is not contained in the prompt) — supply the relevant content through `--task`/`--scope`, and treat a `completed` run with empty findings accordingly. This is the only full mitigation when even sandboxed execution of repo-influenced commands is unacceptable.
- A 30-minute outer timeout. Change it only when the user explicitly supplies another timeout.
- No piped Git diff. The prompt is passed through stdin; Claude runs `git diff` and reads relevant files itself.
- Retry watchdog disabled by default. Enable it only with explicit `--watchdog`; the artifact records the choice.
- No `ultrareview` and no `--max-budget-usd`.

Use an explicit repository evidence path when the review is a durable stage gate:

```bash
"$runner" \
  --scope '099e147..HEAD' \
  --task 'Review pagination behavior, compatibility, and test coverage' \
  --artifact 'openspec/changes/example/reviews/claude-pagination-review.md'
```

An explicit artifact path must be a new `.md` file inside the reviewed repository worktree. Git metadata, skill/Codex/Claude configuration directories, repository-external paths, `..` traversal, and symlink escapes (including a pre-existing symlink, dangling or not, at the artifact or sidecar path) are rejected before any file is created. Its sibling sidecar directory must also be absent. Before partial, final, or failure publication, the runner rechecks that the artifact is a regular non-symlink file and that its canonical parent remains the reserved repository directory. Before wrapper-owned sidecar writes or cleanup, it also rechecks the canonical sidecar directory, direct-child filename, and that a target is absent or a regular non-symlink file. An unsafe artifact or sidecar path fails the run instead of publishing to or cleaning a replacement path. These pathname checks reduce accidental and tested symlink swaps; they are not an FD-based `openat`/`O_NOFOLLOW` guarantee against every local TOCTOU race. `--slug` accepts 1-80 characters that must start with a letter or digit, followed by letters, digits, dots, underscores, or hyphens.

Without `--artifact`, the runner writes `.omx/artifacts/claude-<slug>-<timestamp>-<pid>.md`. That is a runtime diagnostic artifact and does not automatically satisfy a repository rule requiring committed or non-`.omx` gate evidence. Two follow-ups keep the evidence trail honest: (1) when a review is gate evidence, write it to the repository-governed path via `--artifact` and commit it (`git add` + commit) promptly once the gate passes — an untracked evidence file is a missing evidence file at commit time, and the runner-owned `<artifact>.d/` sidecar (prompt/stdout/execution record) is runtime-only: remove or exclude it before the evidence commit rather than `git add -A`-ing raw reviewer output; (2) `.omx/artifacts/` accumulates one runtime diagnostic per run — periodically delete reviewed diagnostics whose evidence role has been superseded by a committed gate artifact.

### Stability Options

- `--no-safe-mode`: re-enable Claude customizations (project/user CLAUDE.md, hooks, skills, plugins, MCP). Trusted repositories only — the default `--safe-mode` is the boundary that keeps the reviewed repo's own hooks/MCP/context from executing in the reviewer.
- `--safe-mode`: accepted for compatibility; already the default.
- `--no-tools`: run with `--tools ""` (no tools at all). The untrusted/archived-repository mode.
- `--debug`: preserve a debug trace and allow Claude session recovery data instead of using `--no-session-persistence`.
- `--fallback-model <models>`: enable Claude print-mode model fallback using an explicit model list.
- `--watchdog`: opt in to `CLAUDE_CODE_RETRY_WATCHDOG=1`. Do not enable it as an unexplained default.
- `--timeout <duration>`: override 30 minutes only when the user explicitly requested another timeout.

The runner exposes `ASK_CLAUDE_TEST_*` environment seams (staged failure/signal injection) used by its regression suite; they are no-ops unless a variable is explicitly set, and they exist for tests — never set them in production runs.

## Process Lifecycle

Distinguish the three identifier layers that may appear when a host agent (Codex, WorkBuddy, Claude Code, zcode, Trae, oh-my-pi, or any other) executes this skill:

1. The host agent's outer orchestration task/cell identifier (if any) controls only the agent-side wrapper.
2. The shell/session identifier returned by the host's command-execution tool controls the still-running runner process.
3. Claude's JSON `session_id` identifies the model session and belongs in the artifact.

If the host's command-execution tool returns a session identifier, keep polling that exact session until a real exit code is returned. A wait/timeout call returning empty output does not mean the runner or Claude finished. Intermediate silence is neither success nor failure evidence.

Do not terminate a healthy review before its effective timeout merely because it has been silent for several minutes. Early termination is allowed only for a confirmed provider error, permission wait, resource failure, explicit user cancellation, or another concrete failure. The default review window is 30 minutes.

## Completion Contract

A review is successfully collected only when all of the following are true:

1. The real runner process exited with code `0`.
2. Raw stdout is non-empty valid JSON.
3. `terminal_reason` is `completed`.
4. `structured_output` satisfies the review schema.
5. The finalized markdown artifact and `execution.json` sidecar exist.

A `NEEDS_ATTENTION` or `BLOCKED` verdict is still a successfully collected external review; it is not a runner failure. Empty output, invalid JSON, an invalid terminal reason, timeout, signal, or provider/CLI error must produce a failure artifact and must never be rewritten as PASS or as “no findings.”

## Artifact Layout

The runner creates the markdown artifact before launch and continuously preserves evidence in a sibling `<artifact-name>.d/` directory:

- `prompt.txt`
- `stdout.json`
- `stderr.log`
- `execution.json`
- `command.txt`
- `process-tree.log`
- `process-tracking-errors.log` when runtime tracking degrades
- `git-before.json`, `git-after.json`, and status snapshots
- `sandbox.sb`
- `debug.log` when `--debug` is used

Caller-supplied task/scope metadata and the generated prompt are scanned before durable publication or Claude launch. A match is replaced with redacted placeholders and fails preflight. If dependency failure or an external signal happens before caller metadata scanning completes, preflight evidence uses `[REDACTED: caller metadata not yet scanned]` instead of the original task/scope. Claude stdout, stderr, and debug data are captured in private temporary files first (stdout/stderr and the prompt in a dedicated runner-owned directory that the provider sandbox cannot write; the debug trace lives in the provider's own temporary directory because Claude writes it there) and scanned before publication; a match or scan failure blocks raw publication, clears provider-derived payloads from `execution.json`, writes redacted placeholders, records non-sensitive rule IDs and a `match_count` whose value is rule activation count in `secret_scan`, and fails the run. This is a defensive pattern scanner, not a proof that arbitrary output contains no sensitive information.

When review of credential-handling code or synthetic fixtures triggers `sensitive_output_detected`, preserve that failure artifact. One narrow retry is allowed with an explicit prompt instruction not to quote credential-like literals or fixture values. Do not disable or weaken scanning. If the retry also triggers, report the review as unavailable.

`execution.json` records timestamps, duration, wrapper/review PIDs, exit and timeout state (including the `timeout -k` kill-after path), termination signal, safe/no-tools/debug/watchdog/fallback settings, sanitized provider host, Claude session and duration fields, `usage`, full `modelUsage`, `permission_denials`, `structured_output`, terminal reason, sandbox mode, Git fingerprints, mutation details, process-tracking degradation evidence, `tool_usage` source and collapsed tool counts when provider JSON or debug evidence exposes them, and remaining process IDs. A normal print JSON result without tool events is explicitly marked `source=unavailable`; it is not proof that a named tool ran. In debug mode, a trace containing `tool_dispatch_end` records that cannot be fully parsed is `debug-trace-parse-failed` and a completed review fails closed instead of silently losing tool evidence.

The runner requires Git, `jq`, GNU `timeout`/`gtimeout`, `grep`, `ps`, `pgrep`, `mktemp`, `awk`, `head`, Perl with `Time::HiRes`, and a working SHA-256 implementation (`shasum` or `sha256sum`). Git and GNU `timeout`/`gtimeout` are resolved and probed before artifact reservation — a host missing either exits 69 with no artifact — and every other runtime dependency and temporary-capture failure fails closed after artifact reservation and produces terminal preflight evidence. Process cleanup records an identity made from PID metadata and revalidates it before sending TERM or KILL, including external signal handling; a reused or mismatched PID is reported but never terminated. A runtime `pgrep` or live-process identity failure is recorded in `process_tracking`; a review that otherwise completed then exits `70` with `process_tracking_degraded`.

The provider host is derived without credentials, and actual model names come from `modelUsage`. Do not describe the result as an Anthropic Claude opinion when the artifact shows a compatibility endpoint or a non-Anthropic model.

The mutation check compares HEAD, index, status, working-tree diff, and staged-diff fingerprints while excluding runner-owned artifact paths. The snapshot git calls are bounded by a 5-minute timeout and neutralize repo-config-driven execution (fsmonitor, hooksPath, diff drivers, and every configured clean/smudge filter is overridden with an identity conversion); a repo-configured process filter cannot be neutralized this way, so if one is configured the artifact carries a WARNING disclosing it and the snapshot fails closed if the filter blocks or breaks. Explicit artifact path components are restricted to literal-safe characters and are excluded using literal Git pathspec semantics. A change is a warning, not proof that Claude caused it; concurrent user or agent edits may be responsible. Never revert such changes automatically.

On macOS, the sandbox is limited provider-process repository/Git/skill write protection. It allows broad file reads, process execution, and network access, while denying only selected credential locations; it is not a secrets-exfiltration boundary for a hostile repository. On hosts where the sandbox is not applied (or the canary degrades), the published review text and the prompt sidecar are unauthenticated — a repository-steered reviewer on such a host can author the artifact content; the artifact carries a WARNING whenever this applies. Wrapper-owned artifact writes are separately constrained by the repository path policy above. On systems without `sandbox-exec`, the artifact marks isolation as `prompt-only`; the mutation check is then detection evidence, not write prevention. `CLAUDE_CONFIG_DIR` (default `~/.claude`) is deny-by-default for writes: an enumerated runtime subset (projects/todos/sessions/metrics/telemetry/history and similar state) is re-allowed, and every code-bearing config surface (settings.json, settings.local.json, CLAUDE.md, hooks/, commands/, agents/, skills/, plugins/) is re-denied; those runtime writes are outside repository mutation detection.

## Failure Handling

- After valid arguments, repository resolution, and safe artifact reservation, preserve the markdown artifact and sidecars on dependency/init failure, provider non-zero exit, timeout, TERM, INT, HUP, empty stdout, invalid JSON, invalid schema, invalid terminal reason, unparseable debug tool records, or runtime process-tracking degradation. An unsafe sidecar path or terminal Markdown publication failure exits `74`; when the sidecar remains safe, `execution.json` records `sidecar_path_unsafe` or `artifact_write_failure` and retains the original preflight reason where available. Invalid arguments or unsafe artifact paths are rejected before artifact creation.
- Finalize failure evidence before cleaning temporary debug data or descendants.
- Never infer findings from partial output or process silence.
- Do not expose full environment dumps, full process argv, provider URLs containing credentials, tokens, or secrets in artifacts or diagnostics.
- Do not kill unrelated processes. The runner tracks only its sampled review process tree and records any process that remains. Preflight fails closed when the selected `pgrep -P` probe or full `ps` identity probe is unusable; runtime failures are explicitly recorded and make an otherwise successful review uncertain.

## Maintenance Verification

```bash
# Resolve the skill directory from this SKILL.md location (agent-neutral).
skill_dir="<path-to-this-skill-directory>"   # e.g. ~/.agents/skills/ask-claude
bash "$skill_dir/scripts/test_run_review.sh"
bash "$skill_dir/scripts/validate_skill.sh"
```

`validate_skill.sh` is self-contained and checks the shipped frontmatter, required sections, script executability, shell syntax, invariant flags, and production-file embedded-credential patterns without requiring PyYAML in the active Python environment. Synthetic credential fixtures in `test_run_review.sh` are intentionally excluded from that static credential scan and are covered by runtime redaction tests. Runtime verification requires Git, `jq`, GNU `timeout`/`gtimeout`, `grep`, `ps`, `pgrep`, `mktemp`, `awk`, `head`, Perl with `Time::HiRes`, and `shasum` or `sha256sum`.

Optional extra check when a Codex-style system skill-creator is present at `${CODEX_HOME:-$HOME/.codex}/skills/.system/skill-creator`:

```bash
python3 "${CODEX_HOME:-$HOME/.codex}/skills/.system/skill-creator/scripts/quick_validate.py" "$skill_dir"
```

That command additionally parses the YAML frontmatter and requires PyYAML; it is not required for the skill to function under other agents.

Task: {{ARGUMENTS}}
