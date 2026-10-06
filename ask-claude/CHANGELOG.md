# Changelog — ask-claude

All notable changes to this skill are documented here. Skill version lives in
the SKILL.md frontmatter (`version:`); the bundled runner carries its own
`runner_version` for runtime diagnostics.

## 1.7.2 — 2026-09-24

### Changed

- SKILL documents the naming rationale: the skill is deliberately
  `ask-claude` (no `-review` suffix) because it covers general
  consultation as well as code review; the `-review` suffix on the
  sibling runners marks review-only scope. Documentation-only; no
  runner behavior change.

## 1.7.1 — 2026-09-23

### Fixed

- **shared capture root hardened (Medium)**: the `ask-claude-shared/` capture
  root is symlink-guarded, created, and tightened to 0700 before use — a
  foreign-owned root fails the run closed via
  `captures_dir_creation_failure` (a same-user world/group-writable root we
  own is tightened, not rejected — the 0700 tightening closes the squatting
  window) — closing a capture-substitution vector on shared-TMPDIR hosts;
  the runner no longer recursively deletes the shared parent (an empty-only
  `rmdir` race could fail a starting concurrent run).
- the signal/EXIT handlers are installed before the on-disk sidecar creation,
  so an early TERM/INT/HUP can no longer leak an empty sidecar directory that
  would block a documented retry at the same path.

### Changed

- preflight redaction placeholders distinguish provider-derived detections
  (`provider-host`, `claude-version`) from caller-input secrets, so operators
  do not rewrite clean task text that never contained a secret.
- the secret rule set now matches gitlab tokens (`glpat-`), Slack tokens
  (`xox[baprs]-`), generic `sk-…` keys, and bare `secret|token =` assignments
  (parity with the kimi sibling's scanner), and the prompt sidecar is
  re-scanned at publication time: a prompt.txt swapped mid-run can no longer
  inject unscanned text into the durable artifact.
- a world/group-writable shared capture root is tightened to 0700 before use
  (a foreign-owned root fails the run closed); the earlier claim that the
  runner "cannot run commands during mutation snapshots" is scoped to
  clean/smudge — process filters are disclosed, not neutralized.
- a missing or non-GNU `timeout`/`gtimeout` binary now dies closed (69)
  immediately after resolution — before any git probe — instead of hanging
  preflight or surfacing as a wrong diagnosis; `--fallback-model ""` is
  rejected like the other value-bearing options; a swapped/removed prompt
  sidecar is recorded as `prompt_path_unsafe` (74) with the quarantined bytes
  overwritten, not as a process-tracking degradation.
- `provider_host` strips query/fragment material after the userinfo strip, so
  gateway credentials riding after the host cannot reach the record.

## 1.7.0 — 2026-09-22

### Changed

- **`--safe-mode` is now the default (High)**: live probing showed the reviewed
  repository's own Claude config surface executing in the reviewer under the
  previous default — repo-shipped `.claude/settings.json` hooks (SessionStart
  and PreToolUse) ran arbitrary shell commands and repo `.mcp.json` stdio
  servers were spawned, because `--dangerously-skip-permissions` plus ambient
  discovery leaves project config live and the sandbox denies config *writes*
  only. `--no-safe-mode` opts back in for trusted repositories; the choice is
  recorded in `execution.json`. The SKILL consultation command defaults to
  `--safe-mode` too.
- **`--no-tools` mode added**: forwards `--tools ""` for untrusted/archived
  repositories. The reviewer sees only the task/scope text and is instructed
  to return `BLOCKED` when the material is not contained in the prompt; the
  artifact and `execution.json` disclose the mode. Closes the gap where the
  documented untrusted-repo mitigation had no runner equivalent.

### Fixed (omp review rounds 30-48)

- **process identity reduced to `lstart,comm`**: reparented descendants
  (parent exited → re-parented to launchd) were misclassified as PID reuse
  under the old `ppid`-based identity, so the runner's own cleanup never
  signalled its own orphans; `pgid` was also dropped because GNU timeout
  setpgid(0,0)s itself right after exec, making a fork-time pgid sample go
  stale within milliseconds (both match the kimi sibling's documented
  rationale).
- **final `execution.json` write guarded**: the record write's status was
  never checked, so a jq failure published an empty/`running` sidecar while
  the run reported `completed`/exit 0. Now fails closed
  (`execution_record_write_failure`, runner exit 74) and republishes a
  minimal terminal record so polling hosts never wait on
  `status:"running"` forever.
- **exit 137 classified as kill-after only when elapsed wall time reached the
  outer timeout**; an external SIGKILL (OOM, operator) stays
  `claude_exit_nonzero` with the exit code preserved.
- **dangling symlink at the artifact path rejected** (`-L` check) — a
  pre-planted symlink used to be followed by the reservation write, creating
  a file outside the worktree; the sidecar path gained the same check.
- test-only `ASK_CLAUDE_TEST_*` injection seams documented in SKILL.md and a
  dead `forced_exit_code` variable removed.
- **artifact staging paths guarded**: the predictable `<artifact>.partial/.final/
  .finalization-failure.$$` redirects (the last unguarded write surface) now
  revalidate parent, leaf charset and non-symlink state before every write, so
  a planted staging symlink can no longer divert review content outside the
  worktree (regression-tested).
- **process-tree.log revalidated on read**: a swapped/replaced log no longer
  silently truncates tracking or drives kill decisions — release and finalize
  degrade tracking fail-closed (`process_log_path_unsafe`) instead of trusting
  unvalidated pids (regression-tested).
- `started_at` and `started_at_epoch_ms` are now captured on the same instant,
  so `duration_ms` matches the recorded ISO pair.
- **artifact publication is now part of the trust contract**: a rejected or
  swapped `stdout.json`/`stderr.log` can no longer be read back into the final
  artifact or drive its `Verdict` line — the raw sections print explicit
  withholding placeholders instead (regression suite extended).
- **linked-worktree Git write boundary closed**: the sandbox now denies writes
  to the shared `GIT_COMMON_DIR` (config/hooks/refs), mirroring the omp port —
  previously a worktree whose main repo lived under an allowed write root
  exposed `<main>/.git` to the sandboxed reviewer.
- `claude --version` output is secret-scanned before publication, and a
  provider-derived `terminal_reason` is now cleared together with the other
  payloads when a secret match or scan failure quarantines the run.
- the relocated-`CLAUDE_CONFIG_DIR` deny compares canonical paths (an aliased
  spelling of `~/.claude` can no longer void the enumerated runtime write
  set), the `Final Prompt` section uses the full sidecar path validator, and
  a swapped `process-tracking-errors.log` degrades tracking fail-closed
  `process-tree.log`/`process-tracking-errors.log` are likewise reported —
  whether swapped, removed, or recreated (an append must not silently
  resurrect a removed evidence file) — and the Final Prompt gate requires an
  existing regular `prompt.txt`.
- the two `claude --version` preflight probes are bounded by the same
  timeout discipline as every other git call, and the derived
  `provider_host` is scanned through the same redaction ladder before
  publication (a gateway credential in the hostname can no longer reach the
  record); a repo that configures git process filters is disclosed via an
  artifact WARNING.
- **release decisions no longer trust the evidence log**: the tracked tree is
  kept in runner memory (unioned with the log only when the log passes path
  validation), so a forged/swapped/truncated `process-tree.log` can neither
  direct TERM/KILL at an unrelated process nor suppress cleanup of genuinely
  tracked descendants; the dangling-symlink replacement of
  `process-tracking-errors.log` is classified as untrusted rather than
  "never existed", and the tracking-degradation escalation keys on the
  in-memory flag so removing the evidence file cannot un-report it; both the
  TERM and the KILL leg of the release read the same in-memory union (a
  TERM-ignoring reparented orphan regression test pins the KILL leg).
- a removed `process-tree.log` is reported as degradation exactly once
  instead of being silently recreated by the next sample (which dropped every
  pre-removal tracked pid from cleanup and evidence), and the runner pins
  `umask 077` so review artifacts and sidecars stay private on multi-user
  hosts regardless of the ambient umask; tracked-tree sampling is additionally
  mirrored into a provider-write-denied union file that is the sole decision
  source for release/evidence, so a forged or truncated `process-tree.log`
  can neither misdirect TERM/KILL at an unrelated process nor hide a genuinely
  tracked one (a real sampled identity mismatch is still reported); the
  union file itself is path-validated before every read, the KILL leg
  carries the same non-empty-identity guard as the TERM leg, and the
  runner's own git snapshot calls neutralize config-driven execution
  (fsmonitor/hooksPath/diff drivers, plus every repo-configured
  filter.<driver>.clean|smudge overridden with an identity `cat` conversion)
  and are time-bounded, so a hostile `.git/config` cannot run its
  clean/smudge commands during the runner's mutation snapshots and a blocking
  filter cannot hang the run; process filters (git-lfs shape) are detected
  and disclosed via an artifact WARNING instead — they keep executing for
  legitimate tooling and are documented as a residual.
- **provider captures isolated from the provider's writable temp**: raw
  stdout/stderr captures (and the review prompt) now live in a dedicated
  runner-owned directory that the sandbox write-denies for the provider,
  while the provider gets its own TMPDIR — a repository-steered command can
  no longer rm-replace a capture by name and have the forged bytes published
  as review evidence; capture paths are additionally revalidated as regular
  non-symlink files before every read (fail closed via the secret-scan
  flags), and a nested `CLAUDE_CONFIG_DIR` inside `~/.claude` no longer
  receives a deny that would void the active store's runtime write set.
- the review prompt capture gets the same regular-non-symlink revalidation as
  the other captures before its reads (a planted FIFO can no longer hang
  preflight), `provider_host` additionally strips query/fragment material so
  gateway credentials cannot reach the record, and a refused capture
  validation is recorded as `capture_validation_failure` instead of
  `artifact_write_failure`.
- capture generation writes revalidate the capture path before opening it
  (a planted FIFO/symlink now fails preflight instead of hanging preflight
  unboundedly or writing through outside the worktree), and the configured
  provider base URL is an exact-string scan needle: if the provider echoes
  the credential-bearing URL into any published text, the run fails closed
  through the existing redaction path (the needle arms only when the base
  URL actually carries userinfo or a credential-shaped query, so a plain
  endpoint echoed by the provider cannot fail a run). Prompt-generation
  writes revalidate the capture path and check their status, and
  `provider_host` handles bracketed IPv6 literals.
- the signal path propagates a finalize-rewritten runner exit code (74/70), so
  the process exit never contradicts `execution.json`; the kill-after (137)
  classification measures elapsed time from the spawn instant instead of
  preflight start.
- the output-trust gate now covers the whole artifact: `## Parsed Review`
  (verdict line and structured-output body) requires a completed run with
  validated outputs, the `Final Prompt` section revalidates `prompt.txt`
  before reading, redaction placeholder writes are checked, and the default
  `~/.claude` store gains the same relocated-`CLAUDE_CONFIG_DIR` write deny
  and blocked-artifact-root treatment as `~/.codex` (regression-tested: a
  mid-run `stdout.json` swap publishes neither the swapped content nor a
  verdict derived from it).
- `provider_host` strips the longest `@`-prefix, so a base URL with multiple
  `@` segments can no longer leave credential residue in artifacts.
- a signal landing during evidence finalization is ignored: once the artifact
  and execution record are published, the runner's own exit code stands and
  published evidence can no longer be contradicted by a late TERM/INT/HUP.
  All signal handlers ignore (not default-terminate) while publishing, so a
  second signal can no longer abort finalization leaving `status:"running"`
  sidecars behind.
- `execution.json.tmp` writes revalidate the target path before opening, and
  a publication failure now marks the secret scan failed so unscanned
  provider payloads can never reach the durable record (regression suite
  extended for staging-path swaps and swapped process logs; the pre-scan
  signal test now accepts both deterministic terminal outcomes).
- SKILL.md no longer claims writes under `CLAUDE_CONFIG_DIR` are "intentionally
  allowed" (the profile has been deny-by-default with an enumerated runtime
  re-allow set since 1.5.5); slug charset documented as
  leading-alphanumeric-then-1-80-safe-chars to match the runner.
- `~/.codex` credential read-deny now also covers the literal default store
  when `CODEX_HOME` points elsewhere (mirrors the kimi sibling's P3-4
  hardening), and the default store is a blocked artifact root.

## 1.6.5 — 2026-09-22

### Fixed (cross-skill parity audit, round 10 — omp review r29)

- **empty-array expansion guarded (High)**: after the new canary degrade
  empties `sandbox_runner`, the bare `"${sandbox_runner[@]}"` expansions in
  `command_display` and the final `exec` aborted the runner under bash 3.2
  + `set -u` (the only bash on macOS) — i.e. the documented "honest
  prompt-only degrade" was a hard crash on exactly the hosts it exists for.
  Both sites now use the `${arr[@]+"${arr[@]}"}` idiom.
- `canon_note` value-gated (see omp 1.1.24).

## 1.6.4 — 2026-09-22

### Fixed (cross-skill parity audit, round 9 — omp review r28)

- **five missed credential params canonicalized**: `GH_DIR`,
  `GIT_CREDENTIALS`, `NETRC`, `NPMRC`, `PYPRC` were left raw while the
  others were wrapped in 1.6.3 — with a symlinked `~/.config` their denies
  stayed inert while the ISO claimed "selected credential reads denied".
- `canon_unavailable` WARNING appended to the isolation description when
  realpath resolution is impossible (perl missing).

## 1.6.3 — 2026-09-22

### Fixed (cross-skill parity audit, round 8 — omp review r27)

- **credential params canonicalized**: every `-D` credential path now passes
  through `rp_path()` (realpath, literal fallback) — a symlinked store or
  config dir (`~/.ssh -> Dropbox`, `~/.config/git` symlinked) made its
  read-deny silently inert.
- **liveness diagnosis preserved**: the claude-liveness degrade string is no
  longer overwritten by the generic availability text; the failing canary is
  named in `isolation.description`.
- disallowedTools test assertion restored to the exact whole-argument form;
  the 1.6.1 "write set completed from live-verified state" wording is scoped to
  the live review it was enumerated from; extend the set when a denial surfaces.

## 1.6.2 — 2026-09-22

### Fixed (cross-skill parity audit, rounds 6–7 — omp reviews r25/r26)

- **credential read-deny parity completed**: `~/.yarnrc.yml` (npmAuthToken)
  and `~/.config/git/credentials` (git XDG store) added; the omp runner had
  them since 1.1.11 while the 1.5.3 "completed" claim covered only the rest.
- **claude-liveness canary** (1.6.1): `claude --version` under the profile
  must succeed; failure degrades to prompt-only.
- **write set completed from live-verified state** (1.6.1): `security/`,
  `session-env/`, `tasks/`, `backups/`, `bash-commands.log`,
  `mcp-*cache.json`, `.last-cleanup`.
- **profile ordering single-sourced** (1.6.0): target denies → CLAUDE_*
  runtime allows → config re-denies (incl. `skills/`, `plugins/`); the
  blanket `CLAUDE_HOME` allow and its duplicate mid-profile block removed;
  enforcement canary uses positional args.
- `runner_version` bumped to 1.6.2 (was 1.4.10 — runtime attribution drifted
  behind SKILL.md).

## 1.5.9 — 2026-09-22

### Fixed (cross-skill parity audit, round 6 — omp review r23)

- **runtime allow-set re-asserted after the target denies**: the
  `CLAUDE_*` runtime write set (and the code-bearing config re-denies)
  now sit at the END of the profile, after `WORKSPACE`/`GIT_DIR`/
  `SKILL_DIR`/`CANARY_DIR` — with a home-rooted toplevel the target deny
  would otherwise outrank the runtime allows and claude could not write its
  own state, while the ISO still reported `macos-sandbox`. The duplicated
  mid-profile allow block was removed; the profile now has a single
  authoritative ordering (target denies → runtime allows → config
  re-denies).
- `CLAUDE_SKILLS_DIR`/`CLAUDE_PLUGINS_DIR` explicitly re-denied (the
  auto-discovered payload and hook/marketplace surfaces).

## 1.5.8 — 2026-09-22

### Fixed (cross-skill parity audit, round 5 — omp review r22)

- **home canonicalization made fail-safe**: a `cd` failure on an existing
  `$CLAUDE_CONFIG_DIR`/`$CODEX_HOME` (untraversable dir, regular file)
  assigned an empty string, root-anchoring the whole enumerated `CLAUDE_*`
  allow set at `/`. The value now changes only on a successful, non-empty
  resolution.

## 1.5.7 — 2026-09-22

### Changed (parity follow-up — omp review r21)

- the isolation description now states probed-vs-inferred explicitly
  ("probed via a runner-owned write canary covering the same SBPL
  mechanism; repo/git/skill targets inferred") instead of claiming
  canary-verified for rules no probe exercises.

## 1.5.6 — 2026-09-22

### Fixed (cross-skill parity audit, round 4 — omp review r19)

- **enforcement canary no longer skips itself**: the 1.5.5 probe used a
  `mktemp -d` inside the reviewed repo and silently skipped the check when
  that failed (read-only/foreign-owned checkouts are supported inputs),
  while the run still reported `macos-sandbox … (canary-verified)` — the
  same fail-open sibling bug ask-omp-review fixed in 1.1.3. The probe now
  targets a runner-owned `CANARY_DIR` (`mktemp -d` under TMP_DIR, added to
  the profile's write-denies); a `canary_dir` creation failure fails the
  canary, and the dir is cleaned on both paths. The reviewed repo is never
  touched.

## 1.5.5 — 2026-09-22

### Fixed (cross-skill parity audit, round 3 — omp review r18)

- **`CLAUDE_HOME` inverted to deny-by-default + runtime allow-list**: the
  1.5.4 six-path re-deny left `~/.claude/skills/**` (auto-discovered
  instruction payloads) and `~/.claude/plugins/**` (hooks + marketplace
  manifests loaded/executed by the host's later sessions) writable, so the
  persistence class it claimed to close stayed open one directory over.
  The profile now denies `CLAUDE_HOME` wholesale and re-allows only the
  runtime write set (projects/, todos/, sessions/, session-data/,
  shell-snapshots/, metrics/, telemetry/, history.jsonl, cost-tracker.log).
- **homes canonicalized**: `claude_home`/`codex_home` now pass through
  `cd && pwd -P` like every other profile param — uncanonicalized SBPL
  literals are silently inert (a symlinked `$HOME`/`CLAUDE_CONFIG_DIR`
  would void both the allow and the denies).
- **enforcement canary**: sandbox apply plus a controlled repo-local write
  probe must both behave (apply ok, write denied); otherwise the run
  degrades honestly to `prompt-only` with the isolation description
  updated, instead of running unenforced while reporting macos-sandbox.

## 1.5.4 — 2026-09-22

### Fixed (cross-skill parity audit, round 2 — omp review r16)

- **`CLAUDE_HOME` write allow narrowed**: the blanket
  `(allow file-write* (subpath CLAUDE_HOME))` let a steered reviewer
  persistently inject Claude Code's code-bearing user config
  (`settings.json` hooks/permissions, `CLAUDE.md` memory, `hooks/`,
  `commands/`, `agents/`) that the host's own later sessions execute —
  the class ask-omp-review closes with post-allow re-denies. Those paths
  are now re-denied AFTER the runtime write allow (SBPL last-match wins).
- **snapshot diff calls**: `-c diff.external= --no-ext-diff
  --no-textconv` added to the worktree/staged snapshot invocations
  (previously `--binary --no-ext-diff` only — textconv was not disabled).

## 1.5.3 — 2026-09-22

### Fixed (cross-skill parity audit vs ask-omp-review rounds r9-r15)

- **credential read-deny set completed**: `~/.terraform.d` (dir),
  `~/.config/pip` (dir), `~/.pip/pip.conf`, `~/.bundle` (dir),
  `~/.gem/credentials`, `~/.m2/settings.xml`, `~/.gradle/gradle.properties`,
  `~/.cargo/credentials.toml`, `~/.composer/auth.json` added to the sandbox
  profile (the auto-approved read tier could previously pull pip/bundler/
  rubygems/maven/gradle/cargo/composer credentials into review output).
- **egress tools disabled**: `WebSearch,WebFetch` added to
  `--disallowedTools` (the omp r12 finding — a steered reviewer exfiltrating
  private code in a query string — applies to claude's read-tier web tools
  too; `allow network*` in the profile stays, so Bash-level egress is
  documented as a residual).
- **Parity checks with NO code change needed**: (a) the omp credential-write
  vector (`git --output=~/.ssh/...`) does NOT exist here — this profile is
  deny-by-default for writes (only CLAUDE_HOME/TMP/tmp/dev-null
  re-allowed); (b) no setsid/orphan exposure (the runner blocks on the
  review to completion, no intermediate exit path); (c) no canary machinery
  (hence no canary redirect vector); (d) verdict contract is JSON-schema
  (no text classifier to drift). Residual (documented in SKILL.md): the
  reviewer runs with full bash under `--dangerously-skip-permissions`, so
  repo-shipped git diff/textconv drivers execute inside the reviewer —
  the write boundary is the sandbox, `--safe-mode` narrows further, and
  untrusted repos should be reviewed with `--tools ""`.

## 1.5.2 — 2026-09-21

### Fixed (external review follow-up, verdict NEEDS_ATTENTION → fixes)

- **P2-1 docs**: the CHANGELOG compatibility claim is scoped — hosts must
  permit process introspection (`ps`/`pgrep`) and the runtime dependencies;
  hosts whose command sandbox denies `ps` fail closed at preflight with
  `dependency_ps_unusable` (observed on WorkBuddy, 2026-09-21), and Ordinary
  Consultation mode is the only in-host path there.
- **P3 related docs**: added a per-host discoverability prerequisite note
  (each host discovers skills from its own directory; create a per-host
  directory symlink as needed) and a "symlink the skill directory, not
  individual files" deployment note in SKILL.md Host Compatibility Notes.
- P1 gate verified on 2026-09-21: `readlink ~/.codex/skills/ask-claude`
  resolves to `~/.agents/skills/ask-claude`; symlinked self-location resolves
  to the physical skill directory from an unrelated CWD.

## 1.5.1 — 2026-09-21

### Added (absorbed from the Windows port)

- New **Host Compatibility Notes** section in SKILL.md, adapting the Windows
  port's cross-host design (`ask-claude-review` v1.6.9):
  - documents the `ps`/`pgrep` prerequisite and the fail-closed
    `dependency_ps_unusable` behavior on hosts whose command sandbox denies
    `ps` (observed on WorkBuddy 2026-09-21 — ordinary consultation is the
    only in-host path; run the full runner from a terminal);
  - documents host command-timeout conventions (~120s default / ~600s cap on
    TRAE, Claude Code, WorkBuddy; `timeout_seconds` on omp) versus the
    runner's 30-minute outer timeout, with background-task / artifact-polling
    guidance;
  - documents the absence of cross-session coordination (timestamp+PID
    artifact names) and notes the Windows port's deterministic run-id
    single-flight protection as a candidate future feature.

## 1.5.0 — 2026-09-21

### Changed (agent-neutral refactor)

- **Location**: moved from `~/.codex/skills/ask-claude` to
  `~/.agents/skills/ask-claude` (cross-agent shared skills directory). A
  symlink at `~/.codex/skills/ask-claude` restores Codex discovery.
- **SKILL.md**: runner references no longer assume `${CODEX_HOME:-$HOME/.codex}`;
  they now instruct resolving the skill directory from the loaded SKILL.md
  path (works under Codex, Claude Code, WorkBuddy, zcode, Trae, oh-my-pi, or
  any host agent).
- **SKILL.md / Process Lifecycle**: generalized from Codex-specific
  `functions.exec.cell_id` / `exec_command` / `write_stdin` identifiers to
  host-agnostic guidance ("the host agent's outer orchestration identifier /
  command-execution session identifier / Claude's JSON session_id").
- **SKILL.md / Maintenance Verification**: the Codex-system
  `quick_validate.py` invocation is now an optional extra check gated on the
  presence of the Codex system skill-creator; the self-contained
  `validate_skill.sh` remains the primary verification path.
- Added frontmatter `version` field and this CHANGELOG.md (version
  management, aligned with the Windows port `ask-claude-review`).

### Unchanged

- `scripts/run_review.sh` (runner_version 1.4.10), `scripts/test_run_review.sh`,
  `scripts/validate_skill.sh`: these were already self-locating via
  `BASH_SOURCE`; no functional change required.
- macOS `sandbox-exec` security posture: `~/.codex` remains a **credential
  read-deny boundary** and a blocked artifact root by design (it holds Codex
  CLI credentials regardless of where this skill is installed).

### Compatibility notes

- The runner is plain bash invoked by absolute path. Host prerequisites: the
  ability to execute shell commands **plus** process introspection
  (`ps`/`pgrep`) and the runtime dependencies (Git, `jq`, GNU
  `timeout`/`gtimeout`, `grep`, `ps`, `pgrep`, `mktemp`, Perl with
  `Time::HiRes`, `shasum`/`sha256sum`). Hosts whose command sandbox denies
  `ps` fail closed at preflight with `dependency_ps_unusable` (observed on
  WorkBuddy, 2026-09-21) — self-triage on that string; from inside such hosts
  use Ordinary Consultation mode only and run the full runner from a terminal
  or unrestricted host. See SKILL.md "Host Compatibility Notes".
- **Discoverability is per-host**: the skill is invocable from any host, but
  each host discovers skills from its own directory (`~/.codex/skills`,
  `~/.claude/skills`, `~/.trae/skills`, `~/.workbuddy/skills`,
  `~/.agents/skills`); create a per-host directory symlink as needed.
  The `~/.codex/skills` symlinks were verified on 2026-09-21 (`readlink`
  resolves to `~/.agents/skills/ask-claude`).
- Host-specific command timeout conventions (e.g. default 120s in some hosts)
  remain the caller's responsibility; the runner's own outer timeout defaults
  to 30 minutes.
