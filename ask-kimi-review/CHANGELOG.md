# Changelog — ask-kimi-review

All notable changes to this skill are documented here. Skill version lives in
the SKILL.md frontmatter (`version:`); the bundled runner carries its own
`RUNNER_VERSION` for runtime diagnostics.

## 1.6.10 — 2026-09-24

### Added

- SKILL: the default `.omx/artifacts/` directory accumulates one runtime
  diagnostic per run — periodic cleanup guidance added (delete reviewed
  diagnostics whose durable copy is committed; the durable copy under
  `--durable-dir` is the evidence of record).

### Fixed (external omp review of this fix set)

- Symlinked `--artifact-dir` (including the repo-shipped `.omx/artifacts`
  default) is refused before `mkdir` follows it — the previous containment
  check compared a path to its own parent and could never fire, so a
  repo-shipped symlink redirected every evidence write (artifact, prompt,
  command record, execution record, sandbox profile) to a directory the
  repo author controls.
- Sidecar directory pre-existence (`-L` **or** `-e`) now fails the run
  (absence precondition, mirroring the ask-claude sidecar contract): a
  pre-existing directory used to be adopted and written through with no
  per-file revalidation, so symlinked children inside it were followed.
- Symlinked `--durable-dir` is refused (gate marked ineligible,
  `durable-dir-symlink`) instead of copying gate evidence through the
  symlink.

## 1.6.9 — 2026-09-22

### Added (backfilled: shipped without a changelog entry)

- `--skills-dir`: the runner points Kimi at an empty runner-owned
  directory, replacing Kimi's user- and project-skills auto-discovery —
  a reviewed repository can ship project skills whose instructions steer
  the reviewer, and Kimi write tools still execute in `-p` mode, so
  repository-shipped skills must not load into the review session.
- Artifact leaf pre-existence refusal: a pre-existing symlink or any
  existing file at the artifact path (guessed-name pre-planting by a
  hostile local actor with artifact-directory write access) fails the
  run instead of being overwritten. As shipped in 1.6.9 this covered the
  artifact leaf only — the sidecar leaf was refused for symlinks only,
  and symlinked artifact/durable directories were still followed;
  closed in 1.6.10.

## 1.6.8 — 2026-09-22

### Fixed (cross-skill parity audit, round 10 — omp review r29)

- **parent-directory symlinks are no longer dereferenced (High)**: the 1.6.7
  check covered only the final path component, so `foo/id_rsa` with
  `foo -> ~/.ssh` still let `cp` copy the target's content past the
  credential boundaries. The materializer now resolves the source with
  `rp_path` and materializes the resolved-path text whenever the resolution
  differs anywhere in the path; all boundary checks compare resolved paths.
- `canon_note` consumed in the isolation string (value-gated); SKILL.md's
  contradicting stale clause removed and the two new stores documented.

## 1.6.7 — 2026-09-22

### Fixed (cross-skill parity audit, round 9 — omp review r28)

- **strict-scope materialization no longer dereferences symlinks (High)**:
  a changed path that was a symlink (e.g. `config.json -> ~/.ssh/id_rsa`)
  had its TARGET's content copied into the review stream by `cp` through
  `-f`; the link text is materialized instead, so no arbitrary local file
  can be pulled past the credential boundaries.
- **credential_boundaries canonicalized with `rp_path()`** so the guard and
  the (canonical) deny rules agree on symlinked stores.
- `canon_unavailable` marker variable added; SKILL.md and the pinned
  test_execution_template.sh sentence updated to the realpath behaviour.

## 1.6.6 — 2026-09-22

### Fixed (cross-skill parity audit, round 8 — omp review r27)

- **credential_boundaries synced with the new denies**: `.yarnrc.yml` and
  `.config/git/credentials` added to the strict-scope guard list (they were
  added to both profiles in 1.6.5 but not to the list that gates what
  strict scope may copy/allow — a real secret-exposure path).
- **overlap test is now bidirectional**: naming an ancestor of a credential
  boundary (e.g. `--strict-allow-paths "$HOME/.config"`) is refused instead
  of re-allowing every denied child through the appended allow rule.
- credential `-D` params canonicalized with `rp_path()` (symlinked stores
  no longer void their denies); the two remaining raw spellings
  (`BUNDLE_CONFIG_FILE`, `TERRAFORM_CREDENTIALS_FILE`) included.

## 1.6.5 — 2026-09-22

### Fixed (cross-skill parity audit, round 7 — omp review r26)

- **credential read-deny parity completed**: `~/.yarnrc.yml` and
  `~/.config/git/credentials` added to both profiles (strict + non-strict);
  the 1.6.3 "complete set" claim omitted these two.
- `RUNNER_VERSION` bumped to 1.6.5 (was 1.5.2 while SKILL.md was 1.6.4).

## 1.6.4 — 2026-09-22

### Fixed (cross-skill parity audit, round 2 — omp review r16)

- **diff-driver hardening completed**: the 1.6.3 fix covered only the
  snapshot call; the four mutation-fingerprint calls
  (`before/after_worktree_fp`, `before/after_staged_fp`) still produced
  full patch output through repo-controlled drivers in the unsandboxed
  runner. All now pass `-c diff.external= --no-ext-diff --no-textconv`
  (five of five patch-producing `git diff` calls hardened).

## 1.6.3 — 2026-09-22

### Fixed (cross-skill parity audit vs ask-omp-review rounds r9-r15)

- **runner-side diff-driver hardening**: the kimi-side `git diff` snapshot
  inherited repo config — a hostile `.git/config` could ship
  `diff.external`/textconv drivers executed by the unsandboxed runner (the
  same vector fixed in ask-omp-review 1.1.3). The snapshot call now passes
  `-c diff.external= --no-ext-diff --no-textconv`.
- **Parity checks with NO code change needed** (verified against this
  runner's own profile): (a) the omp credential-write vector (`git
  --output=~/.ssh/...`) does NOT exist here — the non-strict profile is
  deny-by-default for writes (only KIMI_HOME/TMP_DIR/dev-null re-allowed);
  (b) the credential read-deny set is complete (pip/bundle/gem/terraform
  were ported FROM this runner); (c) the orphan-kill issue does not apply
  (no intermediate exit path — the runner blocks in `wait`).

## Host-process note (2026-09-22, no code change)

- Verified during the WorkBuddy omp-runner debugging: this runner's process
  model (kimi backgrounded with `&`, runner blocks in `wait` until kimi
  exits — no intermediate exit path) is NOT susceptible to the
  process-group reclamation that orphaned the omp runner's review beyond
  its wait budget. The only exposure is the host force-killing the runner
  task itself (Ctrl-C / TaskStop): kimi is then orphaned and the artifact
  finalizes as INTERRUPTED by the documented interrupt-safe design. Do not
  TaskStop a running kimi review; let it finish.

## 1.6.2 — 2026-09-21

### Fixed (external review follow-up, verdict NEEDS_ATTENTION → fixes)

- **P3-2** `scripts/run_review.sh` (RUNNER_VERSION 1.5.1 → 1.5.2): skip the
  `cd`/`pwd -P` self-location entirely when `KIMI_REVIEW_SKILL_DIR` is set,
  and fail with a clean fatal (exit 64, message on stderr) instead of
  silently producing an empty `skill_dir` if self-location fails.
- **P3-4** `scripts/run_review.sh`: the credential boundary now covers the
  literal `$HOME/.codex` in addition to the `CODEX_HOME`-resolved path. When
  the two differ (a non-Codex host exports `CODEX_HOME` for its own tooling),
  a `CODEX_DEFAULT_DIR` sandbox deny parameter and a `credential_boundaries`
  entry keep the deny boundary anchored to the real Codex CLI credentials.
- **P3-1 / P2-1 docs**: SKILL.md "Host Compatibility Notes" now states that
  deployment must symlink the skill *directory* (BASH_SOURCE does not resolve
  through a symlink on the script file itself), corrects the process-tracking
  prerequisite (`pgrep` is a soft dependency here — degraded runs complete
  with a resource-release warning, unlike ask-claude's fail-closed preflight),
  and the CHANGELOG compatibility claims are scoped to hosts that satisfy the
  documented prerequisites instead of "any host that can execute shell
  commands".
- Symlink existence asserted in 1.6.0 was verified on 2026-09-21 (P1 gate):
  `readlink ~/.codex/skills/ask-kimi-review` resolves to
  `~/.agents/skills/ask-kimi-review`.

## 1.6.1 — 2026-09-21

### Added (absorbed from the Windows port)

- New **Host Compatibility Notes** section in SKILL.md, adapting the Windows
  port's cross-host design (`ask-claude-review` v1.6.9):
  - documents the `ps`/`pgrep` prerequisite distinction: `pgrep` is a soft
    dependency here (degrades to a resource-release warning), unlike the
    ask-claude runner's fail-closed `dependency_ps_unusable` preflight
    (observed on WorkBuddy 2026-09-21);
  - documents host command-timeout conventions (~120s default / ~600s cap on
    TRAE, Claude Code, WorkBuddy; `timeout_seconds` on omp) versus the
    runner's 1800-second outer timeout, with background-task /
    `execution.json` polling guidance;
  - documents the absence of cross-session single-flight protection
    (timestamp+PID artifact names) and notes the Windows port's deterministic
    run-id protection as a candidate future feature.

## 1.6.0 — 2026-09-21

### Changed (agent-neutral refactor)

- **Location**: moved from `~/.codex/skills/ask-kimi-review` to
  `~/.agents/skills/ask-kimi-review` (cross-agent shared skills directory). A
  symlink at `~/.codex/skills/ask-kimi-review` restores Codex discovery.
- **scripts/run_review.sh** (RUNNER_VERSION 1.5.0 → 1.5.1): the default
  `skill_dir` no longer assumes `${CODEX_HOME:-$HOME/.codex}/skills/ask-kimi-review`;
  it is now derived from the runner's own script location (`BASH_SOURCE`),
  with `KIMI_REVIEW_SKILL_DIR` retained as an explicit override. This makes
  the runner work from any install root or symlinked agent home.
- **SKILL.md**: `skill_dir` examples updated to resolve from the loaded
  SKILL.md path instead of a Codex home; added an agent-neutrality note
  (Codex, Claude Code, WorkBuddy, zcode, Trae, oh-my-pi, and others).
- **SKILL.md / Read-Only Boundary**: the `~/.codex` entry in the sandbox
  credential deny list is documented as the Codex CLI config directory,
  independent of where this skill is installed.
- Added frontmatter `version` field and this CHANGELOG.md (version
  management, aligned with the Windows port `ask-claude-review`).

### Unchanged

- `scripts/resolve_model.sh`, `scripts/test_*.sh`: already self-locating or
  parameterized via `KIMI_REVIEW_SKILL_DIR`; no functional change required.
- `agents/openai.yaml`: Codex-side interface metadata kept as-is (harmless on
  other hosts).
- macOS `sandbox-exec` security posture: credential read-deny boundaries
  (including `~/.codex`, `~/.claude`, `~/.ssh`, and others) are unchanged;
  they protect credentials regardless of skill install location.

### Compatibility notes

- The runner is plain bash invoked by absolute path. Host prerequisites: the
  ability to execute shell commands, the `kimi` and `jq` executables, and
  (for `--strict-scope` gate runs) reliable `ps`/`pgrep` process evidence.
  Unlike the ask-claude runner, `pgrep` here is a soft dependency: when it is
  missing or denied, resource-release verification degrades to an explicit
  warning in the artifact and the review still completes. See SKILL.md
  "Host Compatibility Notes".
- **Discoverability is per-host**: the skill is invocable from any host, but
  each host discovers skills from its own directory (`~/.codex/skills`,
  `~/.claude/skills`, `~/.trae/skills`, `~/.workbuddy/skills`,
  `~/.agents/skills`); create a per-host directory symlink as needed.
  The `~/.codex/skills` symlinks were verified on 2026-09-21 (`readlink`
  resolves to `~/.agents/skills/ask-kimi-review`).
- Platform support remains **macOS only** for the sandboxed read/write
  boundary; other platforms degrade to `prompt-only` isolation as before.
- Host-specific command timeout conventions remain the caller's
  responsibility; the runner's outer timeout defaults to 30 minutes
  (1800 seconds).
