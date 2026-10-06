---
name: ask-kimi-review
version: 1.6.10
description: Use when a read-only local Kimi Code CLI second-opinion code or visual review is needed, including diffs, staged changes, commit ranges, screenshots, UI assets, architecture diagrams, security-sensitive changes, and cross-module regressions.
---

# Ask Kimi Review

Use the local `kimi` executable as an independent, read-only reviewer. The skill produces a durable Markdown artifact and never applies Kimi's suggestions automatically.

This skill is agent-neutral: the runner resolves its own skill directory from its script location, so it works from any skills directory (for example `~/.agents/skills`, `~/.codex/skills`, or a symlinked agent home) under any host agent (Codex, Claude Code, WorkBuddy, zcode, Trae, oh-my-pi, and others) that satisfies the Host Compatibility Notes below. When referencing the bundled scripts, resolve the skill directory from the loaded SKILL.md path instead of assuming a fixed agent home.

## Host Compatibility Notes

Absorbed from the Windows port (`ask-claude-review`, cross-host design):

1. **Process-tracking prerequisites**: this runner treats `pgrep` as a **soft** dependency — when it is missing or denied, resource-release verification degrades to an explicit warning in the artifact and the review still completes. (Contrast: the ask-claude runner hard-fails closed at preflight with `dependency_ps_unusable` on such hosts — observed on WorkBuddy 2026-09-21, whose Bash tool denies `ps`/`pgrep` at the host-process level even with the per-call sandbox disabled.) The full `--strict-scope` gate still requires reliable process evidence; treat a pgrep-degraded run as advisory rather than gate-eligible.
2. **Host command timeout vs runner timeout**: host command-execution tools often default to ~120s with a ~600s cap (TRAE `RunCommand`, Claude Code `Bash`, WorkBuddy `Bash`; omp uses `timeout_seconds`, default 600s), while the runner's outer timeout defaults to 1800 seconds. Set the host-side tool timeout to its maximum, and run long reviews as a background task with completion notification, or expect the host call to return before the review finishes and poll `<artifact-base>.d/execution.json` for `status`/`terminal_reason` instead. Never judge completion from host-call silence — minutes without stdout are normal while Kimi reads the repository.
3. **Concurrent invocations**: artifact names use timestamp + PID and the runner has no cross-session single-flight protection; avoid two reviews of the same repo and scope at the same time, or separate them with distinct `--slug` / `--artifact-dir` values. (The Windows port's deterministic run-id single-flight protection is a candidate future feature.)
4. **Symlink the skill directory, not individual files**: the self-location logic resolves through a symlinked directory (`cd` + `pwd -P`), but a symlink placed on the script file itself would resolve `dirname(BASH_SOURCE)` to the wrong tree. Deploy by directory symlink (or a full copy), never by linking `run_review.sh` alone.

## Preconditions

**Platform support: macOS only.** The skill is built and verified on macOS with `sandbox-exec`. The artifact records the actual Kimi CLI version used; do not assume a fixed CLI version. Linux and all other platforms are **unverified**: the runner runs, but the sandbox read/write boundary degrades to prompt-only and `--strict-scope` is marked gate-ineligible as `strict-scope-unenforced` by design. Do not claim sandbox isolation, and do not credit a strict gate, on any platform other than macOS.

Run these checks before invoking Kimi:

```bash
command -v kimi
kimi --version
command -v jq
kimi provider list
# Safe model-key check; never print the raw JSON.
kimi provider list --json | jq -r '.models | keys[]'
```

If `kimi` or `jq` is missing, stop and report the prerequisite. Do not substitute another provider. Do not print credential files or unfiltered `kimi provider list --json` output. Provider checks are preflight-only and must not be copied into the review artifact.

## Select The Model

Use these logical model IDs; the bundled resolver translates them to the configured alias that `kimi -m` actually accepts:

- `kimi-for-coding`: default for ordinary PRs, normal review depth, style checks, and independent files. This keeps the standard quota profile unless a faster route is explicitly requested.
- `kimi-for-coding-highspeed`: opt in for a fast first-pass review, large batches of independent files, or interactive iteration. The local guide describes it as the same coding model as standard with faster output and higher quota use.
- `k3`: use for authentication, authorization, tenant isolation, payments, refunds, settlement, coupons, points, schema/migrations, data consistency, public API compatibility, state machines, concurrency/transactions, security, and cross-module review. The current local config declares 1M context and `max` reasoning effort for K3.

The currently managed aliases for all three logical IDs advertise `image_in` and `video_in`, so they can inspect screenshots, UI mockups, diagrams, and other image evidence. Treat these as runtime provider capabilities rather than permanent guarantees. Before a visual review, verify that the resolved alias still advertises `image_in`; report a missing capability instead of pretending to inspect the image.

Some provider registries expose namespaced aliases such as `kimi-code/kimi-for-coding` instead of the bare IDs. Use `scripts/resolve_model.sh` to match the exact alias or one unique suffix. It fails on missing provider data and multiple matches instead of silently routing to an arbitrary provider. Set `KIMI_REVIEW_MODEL` to override the requested model.

If one model must cover a high-risk review, choose K3. Do not infer quality or quota guarantees from a model name; verify the current provider catalog and report uncertainty.

## Review Scope

Make the scope explicit before the call. Valid scopes include:

- current unstaged worktree: `git diff`
- staged work: `git diff --cached`
- a commit range: `git diff <base>..<head>`
- named files: `git diff -- <paths>`
- visual evidence: media paths detected from the diff plus any explicit local paths, combined with the matching code scope when implementation fidelity matters

Do not pipe a diff into Kimi or interpolate the diff into the normal shell prompt. Ask Kimi to run the appropriate `git diff` and inspect relevant files itself. This avoids shell quoting failures, prompt-size limits, and accidental disclosure of unrelated diff content. With the runner, keep `--scope` and the diff arguments after `--` paired so the fallback snapshot represents the same scope.

`-p` permits Kimi to use repository tools, but tool availability and output limits are runtime-dependent. Materialize an exact diff snapshot before the call as a fallback. Tell Kimi the snapshot path and instruct it to read that file if its own `git diff` is unavailable, ambiguous, or truncated. For a large scope, do not embed the snapshot into the prompt.

If a scope covers more than roughly 50 files or 20,000 changed lines, split it by module or directory into separate review artifacts, then run a short K3 synthesis over the findings. More context is not a reason to send unrelated files together.

When using the runner, pair `--scope` (or the equivalent `KIMI_REVIEW_SCOPE` environment variable) with the same Git arguments after `--`: a staged review is `--scope "git diff --cached" -- --cached`; a range is `--scope "git diff <base>..<head>" -- <base>..<head>`; named files are `--scope "git diff -- <paths>" -- -- <paths>`. The runner rejects a scope label whose tokens do not match the diff arguments, so automation should set both from one source of truth.

For visual review, the runner detects changed media files (`png`, `jpg`, `jpeg`, `gif`, `webp`, `svg`, `mp4`, `mov`, `webm`, `m4v`, `avi`, `mkv`, `mts`, `m2ts`, and `3gp`) from the selected diff and merges them with user-authorized paths in `KIMI_REVIEW_MEDIA_PATHS` (one path per line). Automatic detection covers only files present in the selected Git diff; pass untracked media explicitly. Relative explicit paths are resolved against the invocation directory; use absolute paths for clarity. Literal newlines inside filenames are not supported by this line-based interface. Ask Kimi to call its read-only `ReadMediaFile` tool for every resulting path and to compare the image evidence with the relevant implementation. Do not infer image contents from filenames or terminal text. If the tool, file, format, or model capability is unavailable, record that limitation in the artifact and do not claim the image was inspected. Kimi Code CLI also supports pasted images and video interactively, but this skill uses explicit paths so non-interactive `-p` runs remain reproducible. Under `--strict-scope`, explicit media paths are validated against the credential boundaries and allowlisted automatically; they do not need to be repeated in `KIMI_REVIEW_STRICT_ALLOW_PATHS`.

When a model or provider is new, changed, or not previously verified for visual work, run a small ReadMediaFile smoke test with that exact resolved alias before relying on a visual review. A provider catalog `image_in`/`video_in` flag is a required gate, not proof that the end-to-end `-p` path works. The artifact's `catalog-passed` state means only that the provider advertises the required capability; it is not an end-to-end smoke-test result. If the capability gate fails, continue the code-only review, record the caveat in the artifact, and do not claim the media was inspected.

The capability gate expects the provider catalog's `capabilities` value to be a string array; other shapes fail closed and skip visual evidence.

Provider catalog lookups are bounded by `KIMI_REVIEW_PROVIDER_TIMEOUT_SECONDS` (default 30 seconds) when `gtimeout` or `timeout` is available; a timeout is a provider/precondition failure, not a reason to bypass model resolution.

## Prompt

The runner builds and sends a prompt with the exact scope and these constraints:

```text
Act as a strict senior code reviewer. Review $scope in the current repository.

Read the diff and relevant source, tests, configuration, migrations, and call sites yourself. Keep this review strictly read-only: do not edit, create, delete, rename, commit, push, install packages, or change configuration. Do not ask clarifying questions; state caveats and continue when information is missing.

For each path under Visual evidence, use ReadMediaFile and correlate what is visibly rendered with the relevant source. Do not infer image contents from filenames. If no paths are listed, skip visual review. If any image cannot be read, name it under caveats and do not claim it was inspected. Detected paths are absolute; pass explicit paths as absolute paths when they are outside the repository. The list may contain paths detected from the selected diff as well as explicit user-authorized paths.

Check correctness, regression risk, security and authorization, tenant isolation, data integrity, transaction and concurrency behavior, state transitions, idempotency, API compatibility, failure paths, boundary conditions, and project conventions. Prioritize actionable defects over style preferences. Do not report a concern unless the repository evidence supports it.

Return:
1. Verdict: PASS, NEEDS_ATTENTION, or BLOCKED.
2. Findings ordered by severity. For each finding include severity (P0/P1/P2/P3), file and line when known, trigger or data flow, concrete impact, and a minimal remediation direction.
3. Caveats and files or checks that could not be inspected.
4. A short list of verification commands or tests that should run next.

End the final message with a fenced ```json block of the exact form {"verdict":"PASS|NEEDS_ATTENTION|BLOCKED","findings":[{"severity":"P0|P1|P2|P3","summary":"one line"}],"caveats":"..."} (findings may be an empty array). It restates the verdict above in machine-readable form and must stay consistent with the written sections.

Review scope: $scope
Exact diff fallback snapshot: $diff_snapshot
Visual evidence paths (one per line; none means no visual evidence):
$media_scope
Visual capability preflight: $visual_preflight

If the repository tools cannot retrieve the requested scope reliably, read the exact diff from the fallback snapshot. Treat it as read-only evidence and do not modify or delete it.
```

The runner uses `-p` as the non-interactive review entry point. Do not combine `--prompt` with `--yolo` or `--auto`; the runner intentionally uses the prompt-only invocation accepted by the installed CLI. The runner also passes `--skills-dir` pointing at an empty runner-owned directory, which replaces Kimi's user- and project-skills auto-discovery: a reviewed repository can ship project skills whose instructions steer the reviewer, and Kimi write tools still execute in `-p` mode (the sandbox is the only write barrier), so repository-shipped skills must not load into the review session. The prompt is passed as an argv value, so do not include secrets; scope and media paths may be visible to other local users through process inspection. Prompt-level read-only instructions are not an OS-level guarantee; use the sandbox boundary below when available and retain the defensive mutation check.

## Read-Only Boundary

The prompt is a behavioral constraint, not a write barrier: Kimi can still call a write tool in `-p` mode. On macOS, the runner uses `sandbox-exec` to deny writes under the repository root and `.git` directory while allowing Kimi's config, temporary files, and network access. The exact fallback snapshot is created under the Git directory, so the same write deny prevents Kimi from changing that evidence. The profile also denies reads of common credential directories and files (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.config/gh`, the Codex CLI config directory (`~/.codex`, regardless of where this skill is installed), `~/.kube`, `~/.docker`, `~/.azure`, `~/.config/gcloud`, `~/.git-credentials`, `~/.netrc`, package-manager token files such as `~/.npmrc`/`~/.pypirc`, `~/.yarnrc.yml`, `~/.config/git/credentials`/`~/.gem/credentials`/`~/.config/pip`/`~/.pip/pip.conf`/`~/.bundle/config`, build credentials such as `~/.m2/settings.xml`/`~/.gradle/gradle.properties`/`~/.cargo/credentials.toml`/`~/.composer/auth.json`, and cloud/AI config directories and files such as `~/.terraform.d`/`~/.terraform.d/credentials.tfrc.json`/`~/.claude`) after the broad global read allow, then re-allows the skill directory so the skill itself remains reviewable. The runner resolves `TMPDIR`, the workspace, git, skill, Kimi, and Codex directory parameters with `pwd -P` before passing them to the sandbox; Credential `-D` params are realpath-canonicalized (falling back to the literal spelling when resolution fails); a symlinked `$HOME` or store no longer voids the deny. This avoids symlink mismatches for the directory boundaries while keeping the credential deny list readable. The boundary reduces prompt-injection exfiltration risk but is not a complete secret or network isolation boundary; do not treat reviews of hostile repositories as fully isolated. On other platforms, or when `sandbox-exec` is unavailable, the run is explicitly marked `prompt-only`; treat the mutation check as advisory and do not describe the run as hard-isolated.

## Execute And Capture

Use the bundled runner as the only execution path. It encapsulates scope/diff pairing, model resolution, the sandbox boundary below, the outer timeout, process-tree and mutation evidence, secret quarantine, and the artifact writer. Do not hand-roll a shorter `kimi` command: stripping the runner removes the sandbox, the protected diff snapshot, the execution record, and the interrupt-safe artifact.

```bash
# Resolve the skill directory from this SKILL.md location (agent-neutral; works
# from ~/.agents/skills, ~/.codex/skills, or any symlinked agent home).
skill_dir="<path-to-this-skill-directory>"   # e.g. ~/.agents/skills/ask-kimi-review

# current unstaged worktree (default scope "git diff")
"$skill_dir/scripts/run_review.sh"

# staged work; keep --scope and the diff arguments after -- paired
"$skill_dir/scripts/run_review.sh" --scope "git diff --cached" -- --cached

# a commit range
"$skill_dir/scripts/run_review.sh" --scope "git diff main..HEAD" -- main..HEAD

# high-risk scope on K3 with repo-governed durable evidence
"$skill_dir/scripts/run_review.sh" --model k3 --slug auth-refactor \
  --durable-dir docs/review --scope "git diff main..HEAD" -- main..HEAD

# gate review: strict scope (Kimi may only read the snapshot, changed files,
# and approved paths) and a non-zero exit unless the artifact is gate-eligible
"$skill_dir/scripts/run_review.sh" --strict-scope --require-verdict \
  --durable-dir openspec/changes/example/reviews \
  --scope "git diff --cached" -- --cached
```

The runner exits 0 whenever an artifact was finalized, including a non-zero review exit, a timeout, or empty output; the outcome is recorded inside the artifact. Exit 2 or 3 means a precondition or runner failure before the review started. With `--require-verdict`, exit 4 means the artifact is not gate-eligible (quarantine, empty output, timeout, interruption, missing verdict, or a scope violation). `--slug` (or `KIMI_REVIEW_SLUG`) must match `[A-Za-z0-9._-]{1,60}` and may not contain `..`: it becomes a filename component, and the runner also verifies that the resolved artifact parent stays inside `--artifact-dir`. Env overrides: `KIMI_REVIEW_MODEL`, `KIMI_REVIEW_SLUG`, `KIMI_REVIEW_SCOPE`, `KIMI_REVIEW_ARTIFACT_DIR`, `KIMI_REVIEW_DURABLE_DIR`, `KIMI_REVIEW_TIMEOUT_SECONDS`, `KIMI_REVIEW_MEDIA_PATHS`, `KIMI_REVIEW_KIMI_HOME`, `KIMI_REVIEW_PROVIDER_TIMEOUT_SECONDS`, `KIMI_REVIEW_STRICT_SCOPE`, `KIMI_REVIEW_REQUIRE_VERDICT`, `KIMI_REVIEW_STRICT_ALLOW_PATHS`, `KIMI_REVIEW_PROJECTION`.

### Do Not Terminate Early

The outer timeout is 30 minutes by default (`--timeout-seconds` or `KIMI_REVIEW_TIMEOUT_SECONDS`). It is enforced by `gtimeout`/`timeout` when one is installed and by the runner's native watchdog otherwise (TERM, then KILL after a 5-second grace; the artifact records which implementation ran), so a host without GNU timeout is still bounded. Never kill a run before that timeout unless there is a provider error, a permission wait, or a resource anomaly. Minutes without stdout are normal while Kimi reads the repository; they are not a hang, not a failure, and not a completed review. If a run is interrupted anyway, the runner still finalizes an `INTERRUPTED` artifact with the partial evidence; classify it as caller-terminated, never as a timeout failure.

### What The Artifact Records

The artifact is created with status `RUNNING` before Kimi starts and finalized to `COMPLETED`, `TIMED_OUT`, `INTERRUPTED`, or `FAILED`. It carries the full prompt; a structured execution record (started/finished/duration, exit code, timed-out flag, termination signal, effective timeout command and sandbox parameters, resolved model and provider identity, diff snapshot SHA-256); the raw stream-json stdout separate from stderr; an extracted final assistant message with a verdict (a valid fenced `json-schema` contract is parsed first and is authoritative, otherwise the text heuristic is used) and tool-use summary; process-tree evidence; a mutation check with HEAD and changed-path attribution; and verified resource cleanup. A process exit code alone never makes a review gate-eligible: require a completed run, an extracted verdict, no quarantine/scope violation, and (for machine consumers) `verdict_contract == "json-schema"`.

Raw output that matches secret patterns is quarantined: the artifact keeps only the matched pattern names and the retained raw file paths, and the raw content is never published. Token patterns require a left word boundary, so identifiers such as `task-...` or `ask-...` filenames do not trigger quarantine; real token shapes still do. Treat any exposed credential as leaked and rotate it. Retained raw files are not durable evidence: review them within 7 days, then delete them after the credential review and rotation; do not delete them before that review. When `--durable-dir` is used, the durable sidecar excludes the quarantined raw streams and carries a `QUARANTINED.txt` placeholder instead; the raw streams remain only in the runtime sidecar.

### Scope Enforcement

In strict mode, changed-file copies are materialized from the selected diff
side: range reviews use the new-side blob, staged reviews use the index, and
ordinary worktree reviews use the current file snapshot. Projection mode keeps
the original snapshot and projection sources denied to Kimi after scrubbing.

`--scope` constrains the Git diff and the fallback snapshot; it is not by itself a read boundary for Kimi's tools, and the prompt's "read relevant source" wording lets the model range beyond the diff. Pass `--strict-scope` when the review feeds a strict gate: the review process then runs **outside the repository** in a per-run temporary working directory, and the macOS sandbox switches to a **deny-by-default file-read policy** with no global read allow. Readable content is limited to system paths (`/`, `/System`, `/usr`, `/bin`, `/sbin`, `/Library`, `/etc`, `/var/db`, `/opt/homebrew`, `/dev`), the Kimi runtime (its resolved binary, config home, and native-module cache), this run's dedicated temporary directory (which holds the fallback snapshot), the files changed in the reviewed diff (up to 100), paths approved through `KIMI_REVIEW_STRICT_ALLOW_PATHS` (one per line), and explicit media paths (validated exactly like approved paths and allowlisted automatically — they do not need to be repeated in `KIMI_REVIEW_STRICT_ALLOW_PATHS`). File metadata (names and existence) is allowed globally; only content reads are restricted. Approved paths equal to `/`, `/Users`, or `$HOME` are rejected as too broad, and approved, media, or changed paths that overlap a credential boundary are rejected before launch. No `.git` path is exposed at all, so neither `git show HEAD:<path>` nor path-form canonicalization can bypass the boundary, and any out-of-allowlist read fails with EPERM instead of succeeding silently. The prompt forbids git commands, recursive search, and review-history reads; explicit diff pathspecs that match nothing in the actual diff are rejected before launch — matching is delegated to `git diff --name-only`, so Git magic pathspecs such as `:(icase)` or `:(glob)` resolve exactly as Git does — while options, revisions, and `a..b`/`a...b` ranges pass through. Denied attempts are counted as `scope_violation_attempts` **by provenance, not bare phrase matching**: a tool result containing `Operation not permitted` or `not a git repository` counts only when it (a) pairs the git phrase with a git command in the call arguments, (b) names an absolute path outside the readable set, (c) shows a `../` traversal target, or (d) is a line-anchored shell error shape (`cmd: target: Operation not permitted`) returned by a `Bash` tool call — relative-target denials leave no absolute path for rule (b). Allowed file content that merely quotes these phrases (returned by `Read` and friends) stays benign. Raw log hits are recorded alongside as `scope_violation_log_hits`; a denial expressed without such provenance may go uncounted, but its content still cannot enter the stream. Counted attempts make the artifact gate-ineligible. On platforms without `sandbox-exec`, strict scope cannot be enforced and the artifact is marked gate-ineligible as `strict-scope-unenforced`.

### Sanitized Projection

When the reviewed content itself contains secret-shaped literals — for example this skill's own quarantine regression fixtures — an ordinary run fail-closes into secret quarantine. That is correct, but it leaves no compliant way to complete an external review of such fixtures. `--projection` (requires `--strict-scope`) builds a temporary sanitized projection instead: the diff snapshot and each changed file are copied into the per-run temporary directory with every secret-pattern match replaced by a `[[REDACTED:<rule>]]` placeholder, and Kimi reviews only those copies (the raw snapshot is explicitly denied; the original changed files receive no allow rules). The sidecar `projection.json` records, per entry, the source SHA-256, the projection SHA-256, and the per-rule replacement counts, binding the projection to the original content without exposing it; the artifact is marked `Review target: sanitized-projection` and `execution.json` carries the matching `review_target`. Approved paths (`KIMI_REVIEW_STRICT_ALLOW_PATHS`) are user-authorized and pass through unscrubbed; binary files are copied verbatim. Never use the projection to launder real credentials into a review: it exists so synthetic fixtures can earn a verifiable verdict, and the original-content quarantine behavior is unchanged whenever `--projection` is absent.

### Gate Record

Every run keeps a sidecar directory `<artifact-base>.d/` (the artifact path without `.md`) next to the Markdown artifact:

- `execution.json` — the machine gate record: `status`, `terminal_reason`, `gate_eligible` and non-sensitive `gate_ineligible_reasons`, `failure_reason`, `verdict` and `verdict_contract` (`json-schema` or `text-heuristic`), exit code, boolean `timed_out`, termination signal, epoch-millisecond timestamps and `duration_ms`, timeout policy, resolved model and provider identity, scope mode, `review_target` (`original` or `sanitized-projection`) and violation count, `secret_scan` (detected, scan_failed, sources, rule names), `mutation` (HEAD plus index/status/worktree/staged fingerprints), and `resources` (sampled/remaining/identity-mismatch PIDs)
- `prompt.txt`, `command.txt`, `sandbox.sb` — exact prompt, effective command, and sandbox profile used
- `stdout.jsonl`, `stderr.log` — raw stream-json and stderr (replaced by `stdout.quarantined.jsonl`/`stderr.quarantined.log` with mode 600 when the secret scan quarantines output)
- `projection.json` — only for `--projection` runs: the sanitized-projection manifest binding each reviewed copy to its source (source/projection SHA-256 per entry, per-rule replacement counts)
- `process-tree.log` — sampled PID + identity evidence
- `git-before.json`, `git-after.json`, `git-before.status`, `git-after.status` — mutation fingerprints and status snapshots

`execution.json` starts as `RUNNING` and is rewritten at finalization; it is the polling and gate source of truth — do not judge a gate from the runner exit code or the Markdown title alone. Quarantine, scan failure, empty output, timeout, interruption, missing verdict, scope violations, and unenforced strict scope all mark `gate_eligible: false`.

Artifact and sidecar writes are plain pathname operations, not directory-FD plus `openat`/`O_NOFOLLOW` atomic writes. A hostile local actor with write access to the artifact or durable directory could replace files between the runner's writes. Treat the ownership and permissions of the governed durable path as part of the gate's trust boundary, and credit a gate only from `execution.json` read at that path.

### Evidence Class

The default artifact directory `.omx/artifacts/` is a runtime diagnostic location and the artifact is marked `NOT stage-gate evidence`. When the repository requires review gate evidence (check its AGENTS.md for the governed path, for example `openspec/changes/.../reviews/` or `docs/review/`), pass that path via `--durable-dir`; the runner marks the artifact as durable gate evidence and copies it there. The default directory accumulates one artifact per run: periodically delete reviewed diagnostics whose durable copy (if any) is committed — the durable copy is the evidence of record, the `.omx` copy is not. If the output contains credentials or other sensitive values beyond the quarantine patterns, redact the artifact and report that redaction; never paste secrets into the prompt or artifact.


## Interpret Results

Treat Kimi output as an untrusted second opinion:

1. Reproduce or trace every claimed defect against the current source and diff.
2. Separate confirmed findings, plausible but unproven risks, and false positives.
3. For high-risk work, run K3 independently against the original scope rather than asking it only to judge highspeed's summary.
4. If the artifact has a mutation warning, stop interpretation until the exact status change and its source are known. The status check is post-hoc and cannot detect edits that were reverted, ignored-file changes, mutations outside the repository, or concurrent edits that happen to restore the same status.
5. Do not edit, commit, push, or widen scope as a side effect of this skill. If a finding requires a code change, hand it back to the main implementation workflow.
6. If `Process release` is a warning or `Temporary release` reports a remaining file, treat the run as incomplete and inspect the exact PID/path before interpreting findings. Do not terminate an unrelated process automatically.
7. The verdict is extracted from the final stream-json assistant message at two contract levels, recorded as `verdict` and `verdict_contract` in `execution.json`: `json-schema` when a fenced ```json block validates against the review schema (verdict enum; `findings[].severity` in P0–P3) — it then supersedes the text form — and `text-heuristic` otherwise (inline `Verdict: X` or a `Verdict` heading followed within two lines by the verdict word). The contract is prompt-level rather than provider-enforced; confirm against the raw output before acting, treat "not found" as unverifiable rather than PASS, and require `verdict_contract: json-schema` when a machine-checked contract matters.
8. A runtime-diagnostic artifact (the `.omx/artifacts/` default, marked `NOT stage-gate evidence`) does not satisfy a repository review gate. Only durable gate evidence written to the repo-governed path via `--durable-dir` counts.
9. Use `<artifact-base>.d/execution.json` as the machine source of truth for terminal state: poll it for `status`/`terminal_reason`, and require `gate_eligible: true` before crediting a review gate. The runner's exit code (0/2/3, or 4 with `--require-verdict`) alone never proves gate eligibility.

## Failure Handling

- `kimi` not found: report the missing local CLI and suggest `kimi --version` after installation.
- `jq` not found or model resolution fails: stop before invoking Kimi; install `jq` or set up the required local prerequisite, then rerun the resolver. Do not silently pass a bare model ID to the CLI.
- `401` or provider errors: ask the user to run `kimi login`; do not inspect or print credentials.
- `-p` waits for approval or appears hung: inspect the current Kimi permission configuration and run `kimi doctor`; do not add `-y` or `--auto` to `-p`, because the runner's prompt-only contract must remain intact. Keep the run prompt-only or sandboxed and record the incomplete artifact if it cannot proceed.
- timeout: the runner finalizes a `TIMED_OUT` artifact with partial evidence automatically, via GNU `timeout` when installed or the native watchdog otherwise (the artifact records which implementation enforced the bound); split an oversized scope instead of shortening the timeout, and do not invent findings for the unreviewed remainder.
- non-zero review exit (including provider/API errors): the runner finalizes a `FAILED` artifact with `terminal_reason: failed` and structured `provider-api-error` / `nonzero-review-exit` gate reasons. Run the configured fallback (for example ask-claude) for the same scope; never describe the run as a completed review.
- interrupted run: the runner finalizes an `INTERRUPTED` artifact automatically. Classify it as caller-terminated, never as a Kimi timeout or model failure, and rerun the same scope if the gate still needs a completed review.
- empty output: the runner records an empty-output warning; report the exit code and provider diagnostics; do not invent findings.
- secret quarantine: if the artifact reports quarantined raw output, handle the retained raw files as leaked-credential evidence, rotate exposed values, and rerun only after the source is scrubbed. Quarantined raw files are retained for manual handling only; review within 7 days, then delete after the credential review and rotation. If the flagged literals are synthetic test fixtures that must remain reviewable (for example this skill's own quarantine regression tests), do not scrub the originals; rerun with `--strict-scope --projection` so the review executes on a placeholder-scrubbed projection whose source and projection SHA-256 values are recorded in `projection.json`.
- scope violation: with `--strict-scope`, denied out-of-scope reads are counted in the artifact and `execution.json`, and the run is gate-ineligible even though out-of-scope content never entered the stream. Widen the approved paths via `KIMI_REVIEW_STRICT_ALLOW_PATHS` or accept a non-gate review; do not loosen the sandbox.
- `sandbox-exec` unavailable: the runner records `prompt-only` isolation; treat the review as advisory rather than hard-isolated.
- sandbox profile rejected or the sandboxed command fails before Kimi starts: do not retry without the sandbox automatically; retain the partial artifact, mark isolation as failed/blocked, and require an explicit safety decision before any prompt-only rerun.
- working tree mutation: stop interpretation, use the changed status lines and HEAD movement recorded in the artifact to attribute the change (a concurrent commit moves HEAD; a review-process edit does not), and do not revert user changes automatically.
- review-related process remains after completion: report the PID(s), inspect whether they belong to this run or a concurrent user session, and do not kill them automatically.
