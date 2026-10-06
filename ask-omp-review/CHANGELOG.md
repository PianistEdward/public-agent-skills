# Changelog — ask-omp-review (macOS)

All notable changes to this skill are documented here. Skill version lives in
the SKILL.md frontmatter (`version:`); the bundled runner carries its own
`RUNNER_VERSION` (kept in lockstep).

## 1.1.26 — 2026-09-24

### Added (mall money-audit 现场反馈 29 轮: P1+P2)

- `--diff-paths-file <file>`: one path per line (`#` comments and blank
  lines ignored), mutually exclusive with `--diff-paths` — the file form
  replaces hand-maintained comma lists that silently dropped paths.
  `CODE=0`/`empty-diff` lines now carry `DIFFPATHS=<n>` and the effective
  list is persisted to `<run_dir>/diff-paths.txt` for host verification.
- HEAD-dirty export fingerprint: each export writes a sibling
  `<diff>.fp` (head sha, diff sha256, per-file content sha256) and the
  `CODE=0` line carries `FP=<short>`. The frozen diff does not track the
  worktree — an edit landing between export and review made the review
  read stale content (silent in `--no-tools` mode); the fingerprint makes
  that drift detectable. Committed-range exports are immutable and need
  no fingerprint.

### Changed

- SKILL: `--bash-allow` × `--yolo`/`--no-tools` mutual exclusion stated in
  the mode table (fail-closed CODE=2 stays — a clear startup error beats
  silent degradation); macOS `/tmp` ≠ `$TMPDIR` prompt-path warning (two
  field launch failures were exactly this); `--yolo` context disclosure
  (repo rule files enter the review context, worktree state includes
  uncommitted config/gate changes); durable-review-artifact `git add`
  reminder in result handling; review-cache cleanup note; a 处置后复审
  (re-review) recipe section codifying the fix-round loop (re-export →
  disposition summary in prompt → new tag → verify RID/drift) that
  previously lived only in muscle memory.

## 1.1.25 — 2026-09-23

### Added (Guarded isolation surface; external claude review round-1)

- Overlay denies five tools the omp registry tiers `read` and
  `--approval-mode always-ask` therefore auto-approves: `retain` (tiered
  `read` although it WRITES user long-term memory), `recall`/`reflect` (pull
  private memory into the review context), `debug` (read action is DAP
  process introspection), `github` (read op is a credentialed GitHub API
  call).
- Project-level plugin-package closure: overlay `disabledProviders` now also
  denies `claude-plugins`/`agent-plugins`/`omp-plugins`, and the overlay sets
  `mcp.enableProjectConfig: false` (default true) — a connected project-level
  MCP server is a stdio command spawn, i.e. code execution;
  `--no-extensions` only gates ambient extension-module discovery, never
  plugin packages. Real gap before 1.1.25.
- Selftest covers the new overlay invariants and the verdict extractor.

### Fixed

- Completion verdict extraction replaced the greedy `sed` with a first-match
  `awk` helper (`extract_verdict`, same line/fence anchors as
  `classify_result`): the labelled value of the FIRST contract `Verdict:`
  line wins — a later `Verdict:` mention on the same line could previously
  flip the classification.
- Credential read-deny canary probe list now includes `~/.azure` (the
  `AZURE_DIR` profile deny existed but was never probeable); SKILL candidate
  count corrected 22 → 23.
- Selftest overlay assertions are anchored to exact YAML lines: `hub: deny`
  was satisfied by `github: deny`, `edit: deny` by `ast_edit: deny`, and
  `enableProjectConfig: false` by its own header comment — dropping the real
  key would still have passed.

### Fixed (external claude review round-2)

- Overlay denies `context_notes` (omp 18.1.18 read-tier: with no `text`
  arg its approval is `read`, pulling the user's persistent context notes
  into the review context — same class as `recall`/`reflect`; only
  registered under `compaction.experimentalContextManagement=true`, denied
  anyway for class closure). SKILL documents `todo`/`checkpoint`/`rewind`/
  `ask` as session-scoped read-tier tools deliberately left undenied.
- New selftest assertion pins credential canary lockstep: every credential
  deny rule in the SANDBOX_PROFILE must resolve through CRED_PATHS to a
  probe candidate in the launch loop (a rule without a candidate is a deny
  the canary can never verify).
- Guarded-flags selftest now also asserts `--no-extensions`.

### Fixed (external claude review round-4)

- Completion-contract fence parity is CommonMark-accurate in
  `classify_result`/`extract_verdict`: a closing fence must reuse the
  opener's character with at least the opener's length and carry nothing
  but whitespace. A `~~~` line inside a ``` fence previously flipped the
  state, letting repo-quoted evidence expose an in-fence `Verdict: APPROVE`
  as a fabricated CODE=0 completion (selftest pins both the escape and the
  legitimate-close paths).
- Single-flight stale-reclaim restores the pidfile only into the vacancy:
  the unconditional rename-replace could clobber a live claim that won
  noclobber inside the reclaim window — two omp processes for one rid. The
  run now fails closed to CODE=7 either way.

### Fixed (external claude review round-5)

- Fence recognition is now also indent-bounded (CommonMark: fence lines
  only at 0-3 spaces; 4+ spaces is indented-code literal content, and
  tab-led fence-shaped lines are treated as literal). Previously ALL
  leading whitespace was stripped, so a 4-space-indented ``` line inside
  quoted evidence flipped the state and exposed an in-fence planted
  verdict (fabricated CODE=0, or a hijacked VERDICT= on a REQUEST_CHANGES
  review); a phantom fence could equally mask a genuine column-0 verdict.
  Selftest pins both directions.
- Stale-reclaim re-reads the pidfile immediately before the rename and
  only steals it while it still holds the probed stale claim (a claim
  replaced under us is live). Residual documented: a claim swapped in
  between that read and the mv is still stealable — bookkeeping stays
  consistent and every path fails closed to CODE=7.
- Pre-existing run root / run directory not owned by the effective user is
  refused (rid is derivable; on a world-writable TMPDIR fallback a hostile
  local account could otherwise pre-create the tree and swap artifacts
  between runner writes and omp reads). Fail-closed CODE=2, matching the
  existing symlink-refusal posture.
- `--export-diff` skips non-regular, non-symlink untracked entries
  (counted in `SKIPPED=` instead of being diffed). Verified live: git's
  `ls-files --others` currently does not list FIFOs at all, so the guard
  is belt-and-braces rather than a live hang fix.

### Fixed (external claude review round-6)

- Export-path config-driven execution neutralization completed and made
  honest: every runner-side export git call now also passes
  `-c log.showSignature=false` (signature verification could exec
  `gpg.program` on the `git show` path) and `-c core.fsmonitor=false`
  (fsmonitor hook daemon on index refresh), alongside the existing
  `-c diff.external=`. The overbroad "every config-driven execution
  vector" claim is corrected: `.gitattributes`-mapped
  `filter.<name>.clean` content filters execute on diff with no
  enumerable kill switch — documented as a residual in SKILL.md
  (untrusted-repo HEAD-dirty exports belong on a sanitized copy).
  [Corrected in round-7: the clone mitigation works because an undefined
  filter degenerates to a SILENT IDENTITY conversion (no execution) —
  not because git errors; git only hard-fails when the attacker's own
  `filter.<name>.required=true` is present, which a clone also drops.]
- Single-flight closed at the launch line: the runner re-verifies its
  pidfile claim immediately before exec'ing omp (`CODE=7
  REASON=lost-claim` on mismatch) — a claim displaced by the reclaim
  race can no longer proceed to launch alongside the new owner. SKILL
  documents the new reason.
- Pre-existing run root / run directory owned by this user but
  group/world-writable is now tightened to 0700 (previously accepted
  as-is; a same-group peer could rename/replace entries).
- Selftest param-extraction regexes widened to `[A-Z0-9_]` — the
  digit-bearing `M2_SETTINGS_FILE` was silently exempt from the
  profile/-D drift check and the credential canary lockstep check.
- Untracked-entry type guard is repo-anchored (`-f "$repo/$u"`): the
  original cwd-relative test skipped EVERY untracked file when the
  runner was invoked from outside the repository, silently truncating
  HEAD-dirty exports (SKIPPED=N with the files missing from the diff).
  Caught by a live `--export-diff` smoke; smoke also re-verified the
  healthy path from inside the repo and the FIFO-skip path.

### Fixed (external claude review round-7)

- `git ls-files --others` (HEAD-dirty untracked enumeration) now carries
  the same `-c` neutralization as the diff calls: live-probed on git
  2.54.0, fsmonitor hooks execute on `ls-files --others` index refresh,
  so the uncovered call reopened config-driven execution in the
  unsandboxed runner. Per-call coverage enumerated in the export
  hardening comment.
- SKILL/CHANGELOG filter residual corrected against live probes:
  undefined clean filters degenerate to a silent identity conversion
  (inert, no execution) — the sanitized-clone mitigation's actual
  mechanism; the hard git error requires the attacker's own
  `filter.<name>.required=true` (not inherited by a clone). The
  residual scope also extends to the `--no-index` untracked pass,
  where clean filters apply to attribute-matched files with no
  stat-dirty precondition.
- `usage()` now documents both CODE=7 reasons
  (`already_running|lost-claim`), matching SKILL.md's exit-code
  section.

### Changed

- SKILL.md documents the `--no-tools` `@{{DIFF_PATH}}` requirement, the
  expanded Guarded deny list, the plugin-package/MCP closure, and the
  `modelRoles` injection residual with mitigations.

## 1.1.24 — 2026-09-22

### Fixed (external omp review round-29 follow-up)

- `canon_note` is now value-gated (`== 1`) instead of `${var:+…}` — the
  marker was always non-null, so every successful sandboxed run persisted a
  false "canonicalization unavailable" warning (the honesty marker defeated
  its own purpose); the ordering guard also covers `omp_bin_real`.

## 1.1.23 — 2026-09-22

### Fixed (external omp review round-28 follow-up — omp core again clean)

- `canon_unavailable` marker: when `/usr/bin/perl` is unusable the realpath
  step falls back to raw spellings (SBPL-inert) and the success ISO now
  carries a `WARNING path canonicalization unavailable` note instead of
  silently reverting to the pre-fix behaviour.

## 1.1.22 — 2026-09-22

### Fixed (external omp review round-27 follow-up — no omp core defect found)

- `--bash-allow` rejects an embedded newline on the raw value (the line-wise
  loop could not see it and the pattern list was silently truncated);
  CHANGELOG/version lockstep restored (1.1.21 entry added).

## 1.1.21 — 2026-09-22

### Fixed

- canary_dir/home_canary definitions moved before the CRED_PATHS heredoc
  (an unquoted heredoc expands at run time; the later definition crashed
  every launch under `set -u`, caught live by the r27 launch attempt);
  the selftest pins the ordering for the ten variables the heredoc expands
  (line-end-anchored matcher so the assertion cannot match its own source).

## 1.1.20 — 2026-09-22

### Fixed (external omp review round-26 follow-up)

- **prompt handoff rule settled**: a host-supplied `--prompt-file` source
  ALWAYS wins when it exists and differs from the staged copy (unconditional
  republish — the spoofable mtime test is gone); the staged copy is used only
  when no source is supplied (pure retry/resume), and the tmp-top-level path
  is never read in that case. SKILL.md now documents this rule (the 1.1.19
  text still promised the removed `-nt` behaviour).
- **non-HOME write surfaces denied (High)**: omp's profile was the only
  `(allow default)` one — a sandboxed reviewer could still write
  `/opt/homebrew` (where the omp/git/node binaries live), `/usr/local`,
  `/Library`, `/Users/Shared`, `/Applications` and the resolved omp binary.
  All are now write-denied after the TMP_DIR allow.
- **path params canonicalized (Medium)**: `git_dir`/`git_common_dir` and all
  ~23 credential-store params now pass through `realpath` before entering the
  profile (SBPL matches kernel-resolved paths — a symlinked `.git` or
  `~/.ssh` made its rule silently inert). The `-D` set is generated from a
  single `CRED_PATHS` block and the selftest's param cross-check reads it.
- **preflight ordering (Low)**: `--bash-allow` patterns are validated during
  argument parsing, before the prompt is consumed or the rid is claimed (a
  rejected invocation no longer destroys the host's prompt or leaves a stale
  claim). Dead `conventional_prompt` guard/variable removed (it could
  brick-loop a rid on a planted symlink at a path the runner never writes).

## 1.1.19 — 2026-09-22

### Fixed (external omp review round-25 follow-up)

- republish-by-mtime removed; after the first stage the run-internal copy was
  the only instruction source (superseded by 1.1.20's "host source always
  wins" rule); symlinked `--prompt-file` rejected and the staged copy
  verified non-symlink after the move; unguarded `rm` of a host-supplied
  source removed.

## 1.1.18 — 2026-09-22

### Fixed (external omp review round-24 follow-up)

- prompt handoff gained a no-window path (hosts may write directly to
  `$TMPDIR/omp-review/<rid>/prompt.md`); legacy tmp-top-level path supported;
  canary inventory corrected to ten (`prompt_read_allow`).

## 1.1.17 — 2026-09-22

### Fixed (external omp review round-23 follow-up)

- **staged-prompt read re-allow (High)**: the prompt copy inside the run dir
  was handed to `-p @` while sitting under the RUN_ROOT read deny — the same
  class as the 1.1.14 overlay bug, since omp resolves `@file` in-process.
  `(allow file-read* (literal (param "STAGED_PROMPT")))` is emitted after
  the RUN_ROOT deny, with a `prompt_read_allow` canary.
- **retry no longer consumes a world-writable source prompt (Medium)**: the
  first launch MOVES the host prompt into `run_dir/prompt.md` and retries
  re-use that staged copy; the tmp-top-level source is never read again, so
  a sibling sandboxed run cannot swap the instruction file behind the
  documented CODE=3/5 retry. A missing source with a staged copy present is
  accepted (retry path), otherwise the preflight dies.
- **Low**: the staged prompt path joined the symlink-guard loop; the
  in-repo probe trap releases INT/TERM after the probe window (the runner
  honours host cancellation again; EXIT cleanup stays); `usage()` documents
  the export CODE=0 shape and `PARTIAL=`; SKILL.md's run-dir enumeration
  includes `prompt.md` and describes the move-on-first-launch handoff.

## 1.1.16 — 2026-09-22

### Fixed (external omp review round-22 follow-up)

- **target write-denies re-asserted after the TMP_DIR allow (High,
  regression of 1.1.14 fixed in 1.1.15 and re-broken there)**: the final
  ordering is `target denies → TMP_DIR allow → target denies re-asserted →
  runtime store re-allows → config/sessions/RUN_ROOT/PROMPT re-denies`, so
  neither a `$TMPDIR`-staged toplevel nor a `$TMPDIR`-hosted git dir has
  its kernel write deny outranked. A selftest assertion now pins
  `last WORKSPACE-deny line > TMP_DIR-allow line` (the class had regressed
  twice).
- **prompt staged into the run dir (Medium)**: the runner copies the host
  prompt to `<run_dir>/prompt.md` and hands THAT to `-p @`; RUN_ROOT
  (denied read+write for every sandboxed run) then covers this run's
  prompt too, so sibling runs' prompt files can no longer be read or
  rewritten (the retry path could otherwise be fed an attacker-authored
  instruction file). The source path is still write-denied via
  `-D PROMPT_FILE` and removed on success when it matches the conventional
  name.
- **Low**: `--help` rid formula corrected for the empty-tag case; the
  in-repo probe dir is covered by an `EXIT INT TERM` trap and the comment
  no longer claims the repo is never touched; `--bash-allow` patterns
  containing a quote/newline/backslash are rejected at preflight instead of
  corrupting the overlay YAML.

## 1.1.15 — 2026-09-22

### Fixed (external omp review round-21 follow-up)

- **write-rule ordering resolved for good**: the 1.1.14 re-assert of the
  WORKSPACE deny after the runtime store re-allows converted one failure
  mode into another — a reviewed toplevel containing `~/.omp` (`--repo
  $HOME`) voided the store allows and died `CODE=3
  sandbox_profile_incompatible` with the ISO still claiming a verified
  sandbox. Final order: write denies → TMP_DIR allow → **runtime store
  re-allows** → config/sessions/RUN_ROOT/PROMPT_FILE re-denies. The
  selftest now asserts the load-bearing orders (store re-allow after the
  WORKSPACE deny; secret read-denies after the read re-allows) so this
  class cannot silently regress again. Residual documented: with a
  toplevel covering `~/.omp` the reviewer may write omp runtime stores.
- **RUN_ROOT covers all runs**: artifact trees moved under a shared
  `$TMPDIR/omp-review/` parent denied wholesale in every profile (read and
  write), so a sandboxed reviewer can no longer enumerate and overwrite a
  sibling run's `result.md`/`state`/`err.txt` through `git diff
  --output=`. The own-overlay read re-allow is emitted after the RUN_ROOT
  deny.
- **PROMPT_FILE write deny restored** (lost in the 1.1.13 refactor): the
  prompt path is passed as `-D PROMPT_FILE` again and denied literally, so
  the documented same-rid retry cannot be fed a reviewer-authored
  instruction file. `conventional_prompt` points at the real host path.
- **unborn worktree pass counted**: a failing worktree-delta export now
  reports `PARTIAL=1` instead of a silent partial diff with CODE=0.
- **ISO honesty**: success strings state the probed-vs-inferred workspace
  deny, "selected credential reads only", and the absence of a general
  secrets/network boundary; SKILL.md documents nine canaries (incl.
  `overlay_read_allow`), the whole-HOME-minus-enumeration read residual and
  the RUN_ROOT layout.

## 1.1.14 — 2026-09-22

### Fixed (external omp review round-20 follow-up)

- **overlay read re-allow** (High): `RUN_DIR`'s read deny also covered the
  reviewer's own `--config` overlay, which omp treats as a hard error — a
  sandboxed Guarded launch would have died at `Settings.init` on every
  host where the sandbox engages. `OVERLAY_FILE` is now re-allowed after
  the RUN_ROOT deny, with a matching `overlay_read_allow` canary.
- **TMP_DIR ordering** (Medium): WORKSPACE/GIT_DIR/GIT_COMMON_DIR/SKILL_DIR
  denies were re-asserted after the TMP_DIR allow (targets staged under
  `$TMPDIR` had their write boundary voided) — superseded by 1.1.15's final
  ordering.
- **canary hygiene**: probes pass paths as positional parameters (a
  legitimate path containing a quote no longer breaks `sh -c` and
  false-degrades the launch); the credential canary probes all 22
  credential paths (was 6); the workspace write canary probes the
  WORKSPACE rule itself from inside the toplevel (falling back to
  CANARY_DIR with an ISO `inferred` marker).
- **export hygiene**: the diff temp lives in the run dir (no litter in the
  reviewed repo's git dir on interrupt); five export CODE=6 paths emit
  `RID=`/`ERRFILE=` per the documented contract.

## 1.1.13 — 2026-09-22

### Fixed (external omp review round-19 follow-up)

- **profile rule ordering (last-match-wins made load-bearing)**: the read
  re-allows sat AFTER the secret denies, so a reviewed toplevel containing a
  credential store (e.g. `--repo $HOME`) silently voided every credential
  read-deny; the write side had the mirror defect (runtime allows before the
  WORKSPACE deny). The profile is now explicitly ordered: skill-home denies →
  review-target re-allows → **all secret denies last**; write denies →
  runtime re-allows → **config/artifact re-denies last**.
- **per-run artifact directory**: artifacts moved from
  `$TMPDIR/omp-review-<rid>-*` sibling files into a private
  `$TMPDIR/omp-review-<rid>/` directory protected by a single
  `(deny file-write* RUN_DIR)` — sibling runs' `result.md`/`state` sidecars
  were writable from inside the sandbox through the same `git diff
  --output=` primitive (SBPL has no wildcards, so name literals could never
  express that boundary). Hosts read paths from `RESULTFILE=`/`ERRFILE=`;
  the success sidecar is `<result.md>.state`.
- **credential-read canary stderr**: dropped the inner `2>&1` that made
  `cred_read.err` empty by construction.
- **Host Compatibility Notes**: WorkBuddy's nested `sandbox_apply` EPERM is
  now recorded in the notes hosts actually read (5/5 recorded runs degraded;
  the write boundary is overlay-only there ⇒ `--no-tools` for untrusted
  repos), and the bare `prompt-only` ISO gained a reason string so the
  documented degrade detector matches on every path.
- CHANGELOG count corrected (60/60 params).

## 1.1.12 — 2026-09-22

### Fixed (external omp review round-18 follow-up — all Low/Nit)

- credential-read canary's stderr redirect order fixed (a trailing
  `2>/dev/null` re-pointed fd 2 after the capture and left the log empty,
  making "all eight probes capture stderr" untrue for this one).
- classifier accepts `**Verdict**: X` (colon outside the bold) — the
  documented decoration tolerance covered the colon-inside form only;
  selftest adds the case (43 assertions).
- SKILL.md Guarded row now marks the WORKSPACE/GIT_DIR/SKILL_DIR write
  denies as *inferred from the probed mechanism* (the only write-deny probe
  targets the runner-owned CANARY_DIR); the emitted ISO strings were already
  accurate.
- `usage()`: CODE=6 documented in both shapes (git-failure vs empty-diff);
  the setsid die remark corrected (perl `die` exits non-zero, typically 1 —
  not the fixed 126 the comment claimed).

## 1.1.11 — 2026-09-22

### Fixed (external omp review round-17 follow-up)

- **High — canary-log mktemp template fixed for macOS**: Darwin mktemp only
  substitutes TRAILING Xs, so the 1.1.10 `…-canary-fail.XXXXXX.log` template
  produced a literal path — voiding the unpredictability hardening and, on
  the documented same-rid retry, colliding under O_EXCL and wedging the rid
  with CODE=2. The template now ends in Xs, falls back to `mktemp -t`, and a
  stale-path sweep runs first; the ISO only advertises `details:` when a log
  really exists.
- **Medium — verdict separator widened**: `Verdict:` may be followed by any
  whitespace run (tab / double space were classified CODE=5); selftest adds
  tab and double-space cases plus a fenced-block negative (42 assertions).
- **Low — every canary records stderr**: all eight probes capture stderr to
  `$canary_dir/<name>.err` and pass it to the canary log (previously only
  two did, while the docs claimed all).
- **Low — `usage()` per-code shapes**: the status-line block now documents
  which keys each CODE actually emits (2/6/7 carry no RESULTFILE/ISO).
- **Low — credential read-deny gaps**: `~/.config/git/credentials` (git XDG
  store) and `~/.yarnrc.yml` added (latent XDG twins of already-denied
  `~/.git-credentials`/`~/.npmrc`).
- **Low — HOME write canary path randomized**: probed via
  `$HOME/.omp-review-write-canary.$$.$RANDOM` with a matching profile
  literal deny — a fixed name can no longer receive a planted-symlink
  append.
- **selftest**: profile-params vs `-D` cross-check added (no drift in either
  direction; 59/59 verified). Independently verified the same check passes
  for ask-kimi-review and ask-claude.

## 1.1.10 — 2026-09-22

### Fixed (external omp review round-16 follow-up)

- **`sandbox_apply` canary diagnostic**: the apply probe's stderr is now
  captured into the canary dir, and the canary-fail log is always created
  via `mktemp` (guarded unpredictable path) — previously the degrade ISO
  pointed at a log file that was never written, making the most
  consequential degradation undiagnosable.
- **status-line contract**: `ISO=` moved to the END of every terminal line
  (its value contains spaces and was breaking the documented
  whitespace-tokenized parsing ahead of `RESULTFILE`/`ERRFILE`); `usage()`
  documents `MODE=`/`ISO=`.
- **`~/.omp` re-allow completion**: `gpu_cache.json` and
  `agent/last-changelog-version` re-allowed (runtime writes verified for
  omp 18.1.18; neither is a config-injection surface).
- **classifier fence parity**: matches inside fenced code blocks (``` or ~~~)
  are excluded, so a truncated or quoted result carrying a prior artifact's
  `Verdict:` line cannot satisfy the contract; verdict extraction anchored
  to the first match.
- **`--tools ""`** is now an explicit error (it was silently ignored,
  leaving Guarded's full tool surface active for a host that intended to
  strip it).
- SKILL.md updated: eight canaries (probed vs inferred), the emitted
  degrade string with `failed canary:`/`details:`, the CODE=3
  `sandbox_profile_incompatible` row, the `~/.omp` read residual and the
  `run/<id>/broker.token` write residual.

## 1.1.9 — 2026-09-22

### Fixed (external omp review round-15 follow-up)

- **Critical — canary redirect vector closed**: the detach-chain canary
  wrote stderr to a predictable unguarded path (`$err_file.canary`) from
  the UNSANDBOXED runner — a planted symlink truncated an arbitrary host
  file on every launch. The canary now writes into the runner-owned mktemp
  canary dir (unpredictable path, profile-denied, removed after use).
- **High — Guarded launch actually works again**: the 1.1.8 enumeration
  denied `~/.omp/agent/agent.db`, so a real sandboxed omp died
  SQLITE_READONLY at store open with a 0-byte result while the ISO claimed
  canary-verified (verified live via a launch sidecar + err). The runtime
  stores omp must write (agent.db/history.db/models.db + WAL/SHM) are
  re-allowed; config.yml(.lock), sessions/ and terminal-sessions/ (the
  persistent config-injection vectors) stay write-denied. CODE=3 now
  distinguishes `sandbox_profile_incompatible` (SQLITE_READONLY signature)
  from transient empty results so hosts do not retry-loop a deterministic
  incompatibility.
- **Medium — resume attribution**: the resume path reported resume-time
  `MODE=`/`ISO=prompt-only` for sandbox-verified launches; it now reads
  `mode=`/`iso=` from the sidecar (falling back to an explicit
  `(resume: sidecar ...)` marker).
- **Low — canary observability**: every canary failure is recorded with
  its name and stderr (`<rid>-canary-fail.log`), the ISO degrades with
  `failed canary: <name>`, per-launch canary dirs are removed, and the
  canary/residual documentation was corrected (8 canaries, probed vs
  inferred, `~/.omp/run` broker-token residual stated).

## 1.1.8 — 2026-09-22

### Fixed (external omp review round-14 follow-up)

- **High — `~/.omp` runtime subset narrowed**: `agent/cache` (LSP-server
  manifests) and `puppeteer` (installed browser bundle) were re-allowed
  under the 1.1.3 carve-out — both are host-executed/consumed state a
  steered reviewer could poison via `git --output=`. They are no longer
  re-allowed; only logs/run remain (run/daemons broker token documented as
  a residual), and WORKSPACE is now derived from `git rev-parse
  --show-toplevel` so a `--repo` subdirectory cannot narrow the boundary.
- **Medium — ISO/MODE attribution survives completion**: the state sidecar
  is no longer deleted on CODE=0/3/5 — it is preserved as
  `<RESULTFILE>.state` (with `iso=`) — and the terminal status lines carry
  `MODE=`/`ISO=`. Prior rounds deleted the sidecar on every completed run,
  making the effective isolation level unrecoverable.
- **Medium — detach chain made observable + canary-covered**: the setsid
  wrapper now dies WITH a message into ERRFILE (was message-less 126/127,
  misdiagnosed as an omp crash), and a detach-chain canary exercises the
  real `perl setsid -> sandbox-exec -> true` path — a permanent detach
  failure degrades honestly to prompt-only instead of retry-looping.
- **Medium — SKILL.md:105 corrected**: the reviewer side does NOT get the
  export-side diff-driver neutralization (the whitelist cannot inject
  flags into `git show *`/`git diff *`, and the sandbox bounds writes, not
  in-process exec/network) — `--no-tools` is the only complete mitigation
  for untrusted repos.
- **Low — classifier edges**: value terminator added (`APPROVED` no longer
  matches as a prefix), the bold-LABEL form `**Verdict:** X` now matches,
  and the selftest covers both plus the previous cases (38 assertions).

## 1.1.7 — 2026-09-22

### Fixed

- **setsid() success check on macOS**: setsid() returns the new session id
  (not 0) — the `== 0` check misjudged every success as failure and killed
  all Guarded launches with exit 126 one second after launch.

## 1.1.6 — 2026-09-22

### Fixed (external omp review round-10 follow-up)

- **classifier production bug**: real reviewer output
  `Verdict: **REQUEST_CHANGES**` (bold-wrapped value) classified CODE=5
  no_verdict — the anchored regex now accepts an optional bold wrap on the
  value AND requires heading/bold decorations (a bare leading space, i.e. a
  diff-context line, no longer matches — reviewed content cannot satisfy the
  contract on a truncated result). Selftest: +bold/heading cases,
  +diff-context negative case (36 assertions).
- **`~/.omp` carve-out inverted to allow-by-enumeration**: deny the whole
  `~/.omp` tree, re-allow ONLY the runtime write subset (logs/run/cache/
  puppeteer) — `agent/` (config, model dbs, sessions) fully write-denied
  (the `models.db*` vector from round-10 closed).
- **sandbox enforcement canaries**: HOME write deny, repo-local mktemp
  write deny (mktemp failure fails closed), contract-artifact deny,
  credential read deny (first existing path; ISO marks `unprobed` when
  none), omp liveness under profile+overlay, workspace read re-allow — all
  must hold or the launch degrades honestly to prompt-only.
- **state sidecar**: ISO persisted (`iso=`) so overlay-only runs are
  attributable after the fact; prompt path persisted for resume cleanup.
- **Low**: setsid() failure fail-closed (exit 126, no silent non-detached
  launch); export diff_tmp removed on git-failure; export hardening
  applied at the git level incl. the --no-index untracked pass; `--yolo
  --bash-allow` exclusivity; `--thinking`/`--mode` documented as
  non-passable; CODE=4 no longer litters the sandbox profile.

## 1.1.5 — 2026-09-22

### Fixed

- **orphan-kill root cause** (rounds-r13 silent deaths): WorkBuddy reclaims
  the runner process group when the background task ends — every omp beyond
  the 540s wait budget (CODE=4) was killed with an unflushed stdout buffer.
  Launch now detaches via setsid; `--wait-seconds 0` added (unlimited wait;
  documented background-task usage for long reviews). Live smoke: 482s run
  with real EXITED=1 capture, zero orphan kills.

## 1.1.4 — 2026-09-22

### Fixed (external omp review round-12 follow-up)

- **Medium**: PIP_CONFIG_DIR/BUNDLE_DIR denies literal→subpath (dirs were
  inert literals — pip/bundler credentials stayed readable).
- **Medium**: `--no-index` untracked pass hardened with
  `-c diff.external= --no-ext-diff --no-textconv` (was the one unhardened
  runner-side diff invocation; worktree-controlled input).
- **Medium**: review-state freeze — the round-12 artifact reviewed the
  committed 1.1.3 bytes while the working tree already carried the
  -c/YAML fixes; the fix commit now precedes re-export so artifact,
  RUNNER_VERSION and CHANGELOG describe one revision.
- **Low**: credential read-deny canary probes the first EXISTING credential
  path and marks the ISO `unprobed` when none exists; CODE=4 no longer
  litters the sandbox profile; selftest asserts the generated overlay's
  YAML shape (catch-all indent == sequence indent); `--thinking`/`--mode`
  documented as non-passable.

## 1.1.3 — 2026-09-22

### Fixed (external omp review round-11 follow-up)

- **High — `~/.omp` carve-out inverted to allow-by-enumeration**: the
  deny-by-enumeration left omp's live state writable (`models.db`/`-wal`
  actively written minutes before the review; logs/audit, run, cache,
  puppeteer, `gpu_cache.json`, `last-changelog-version` uncovered). The
  profile now denies `file-write*` across the whole `~/.omp` tree and
  re-allows ONLY the runtime subset (logs, run, cache, puppeteer) —
  `agent/` (config, model dbs, sessions) is fully write-denied.
- **High — runner-side export hardened**: `--export-diff` executes
  UNSANDBOXED in the runner process and inherited repo config — a hostile
  `.git/config` could ship `diff.external`/textconv drivers (arbitrary
  exec) on the documented step-1 path the `--no-tools` remedy cannot cover.
  Every runner-side diff invocation now passes
  `-c diff.external= --no-ext-diff --no-textconv`.
- **Medium — credential read-deny set completed** to match the sibling
  kimi runner: whole-dir `~/.terraform.d`, `~/.config/pip`,
  `~/.pip/pip.conf`, `~/.bundle`, `~/.gem/credentials` added.
- **Medium — canary fail-closed**: a `mktemp -d` failure for the repo-local
  write canary no longer skips the canary silently while ISO still claims
  "canary-verified"; the strongest deny is never left unprobed.
- **Low — bare git forms allowlisted**: `git diff`, `git log`, `git show`,
  `git rev-parse` bare entries added (trailing-space prefix patterns never
  matched the bare forms; selftest asserts all four).
- **Low — boundary hardening**: `<gitdir>/review-cache` symlink guard;
  `WORKSPACE` derived from `git rev-parse --show-toplevel` (a `--repo`
  subdirectory no longer narrows the kernel write boundary below the
  worktree); `--yolo --bash-allow` exclusivity; SKILL.md Guarded row now
  enumerates `web_search`, states the egress residual, and quotes the ISO
  degradation token verbatim.

## 1.1.2 — 2026-09-22

### Fixed (external omp review round-10 follow-up)

- **High — `~/.omp` carve-out narrowed**: the blanket write re-allow handed
  the reviewed process the host's live omp config and session databases
  (live-observed: the sandboxed reviewer wrote `agent.db-wal`); a steered
  reviewer could persistently rewrite the global omp config. The re-allow
  is now followed by explicit denies for `config.yml(.lock)`, `agent.db(-wal/
  -shm)`, `history.db(-wal/-shm)`, `agent/sessions`, `agent/terminal-sessions`.
- **Medium — tool blacklist gap closed live**: `web_search` executed under
  Guarded during the round-10 review (network egress from a steered
  reviewer). `web_search: deny` added to the overlay; SKILL.md states the
  residual (any future unenumerated egress tool) and points untrusted repos
  at `--no-tools`.
- **Medium — canary set completed**: credential read-deny canary (`ls
  ~/.ssh` must fail), omp-liveness canary (`omp --version` under the profile
  must succeed), repo-local `mktemp -d` write canary must fail; the ISO
  string no longer claims verifications no canary performs.
- **Medium — linked-worktree git dir**: `git rev-parse --path-format=absolute
  --git-common-dir` is denied for writes as `GIT_COMMON_DIR` (a linked
  worktree's real `.git/config`/`hooks` were outside the boundary).
- **Low — pid 0 wedging**: both liveness checks now require a non-zero
  numeric pid (`kill -0 0` signals the caller's own group and always
  succeeds, permanently bricking a rid from a planted `0|...` pidfile).
- **Low**: `--repo` canonicalization failure guard; prompt path recorded in
  the state sidecar and restored on resume (cleanup now works on the
  documented long-review flow); `--yolo --bash-allow` exclusivity; the
  dead `DIFF_FILE` deny/re-allow pair removed (the diff is readable through
  the GIT_DIR re-allow).
- Known residual (documented): the shared tmp dir's other targets' results
  stay readable through `(allow default)`; treat findings from prior runs
  as host-side knowledge.

## 1.1.1 — 2026-09-22

### Fixed (external omp review round-9 follow-up)

- **High — canary hardened**: the enforcement canary probed a path inside
  the reviewed repo, so a repo-placed symlink could spoof "writes allowed"
  and silently drop the whole run to prompt-only (and the runner deleted
  that repo path). All canaries now run against runner-created paths
  (`mktemp -d` inside the repo for the write canary) and the repo is never
  mutated; a second canary asserts the artifact write-deny and a third
  asserts the reviewer stays sighted (read re-allow).
- **High — write surface mirrored**: the credential set was read-denied
  but write-allowed, so `git log --output=~/.ssh/authorized_keys -p HEAD`
  (allow-listed prefix, auto-approved bash) could truncate/overwrite any
  user file. The sandbox now denies `file-write*` across the WHOLE home
  directory, re-allowing exactly `$HOME/.omp` (omp runtime) and the runner
  tmp dir — with WORKSPACE/GIT_DIR/SKILL_DIR and the contract-artifact
  literals re-denied AFTER the re-allows (SBPL last-match-wins ordering).
- **Medium — unborn+staged+modified**: `HEAD-dirty` on a repo without
  commits now exports BOTH the index (`git diff --cached`) and the worktree
  delta (`git diff`) — previously worktree edits to staged files silently
  vanished from the review (false-APPROVE class).
- **Medium — SKILL.md contradiction removed**: the allowlist limitations
  paragraph no longer claims `--output=` is refused by the bash whitelist
  (contradicting the live-probe record); it states explicitly that the
  whitelist does not constrain git's own writing options and that the write
  boundary is the sandbox layer (ISO-dependent).
- **Low**: prompt cleanup now matches runner-owned tmp naming (the export
  rid and launch rid differ under `--tag` rotation, so the old equality
  check never fired); CHANGELOG wording corrected to match the code.

## 1.1.0 — 2026-09-22

### Fixed (external omp review round-8 follow-up)

- **High — deployment-root blindness**: the credential read-denies for
  `~/.agents`/`~/.claude`/`~/.codex` subsumed the tool's own deployment
  roots — on hosts where the sandbox engages, Guarded reviews of repos
  under those roots (including this skills repo, the primary dogfooding
  target) would blind the reviewer. The sandbox profile now re-allows
  WORKSPACE/GIT_DIR/SKILL_DIR (plus the exported DIFF_FILE) AFTER the
  credential denies (SBPL last-match-wins; placement is load-bearing), so
  the reviewer stays sighted while credential payloads outside the review
  targets stay denied.
- **High — enforcement canary**: the launch probe now verifies the sandbox
  actually ENFORCES its denies (a write canary into the denied WORKSPACE
  must fail), not merely that `sandbox_apply` succeeds; any failure
  degrades honestly to `ISO=prompt-only (sandbox-exec unavailable or denies
  not enforcing on this host)`. The empty-diff CODE=6 line now carries
  `ERRFILE=`/`SKIPPED=`; `--export-diff` no longer requires the omp CLI.
- **Medium — unborn+staged**: a fresh `git init` repo with STAGED changes
  now reviews the index (`git diff --cached`) instead of silently omitting
  the staged content (false-APPROVE vector).
- **Medium — prompt cleanup matches the documented flow**: the prompt file
  is removed on success when it lives under the runner-owned tmp naming,
  regardless of rid equality (export rid ≠ launch rid whenever `--tag` is
  used — the documented per-round tag rotation).
- **Low**: `mv` of the exported diff is checked; selftest covers the
  `### Verdict:` heading form (regression anchor for 1.0.9) and the
  negative list-item case; selftest now 29 assertions.

## 1.0.9 — 2026-09-22

### Fixed (external omp review round-7 follow-up)

- **classifier gap (found in production)**: a reviewer emitting
  `### Verdict: X` (markdown heading) was classified CODE=5 no_verdict —
  the anchored prefix class now includes `#` (`^[#*[:space:]]*Verdict:`),
  same for the verdict extraction.
- **Medium — mv reclaim bound to the probed claim**: after the atomic `mv`
  of a stale pidfile, the moved content is re-verified against the probed
  pid; a mismatch (a newer live claim slipped in) restores the file and
  fails closed to CODE=7 instead of stealing the claim.
- **Medium — credential read-deny set ported into the sandbox profile**:
  the auto-approved read tier could read host credential stores; the
  Guarded profile now denies reads of `~/.ssh`, `~/.aws`, `~/.gnupg`,
  `~/.config/gh`, `~/.codex`, `~/.kube`, `~/.docker`, `~/.azure`,
  `~/.config/gcloud`, `~/.claude`, `~/.agents`, `~/.git-credentials`,
  `~/.netrc`, `~/.npmrc`, `~/.pypirc`, `~/.m2/settings.xml`,
  `~/.gradle/gradle.properties`, `~/.cargo/credentials.toml`,
  `~/.composer/auth.json`, `~/.terraform.d/credentials.tfrc.json`.
- **Medium — tmp siblings via mktemp**: the pidfile owner-update and diff
  temp files are `mktemp`-created (O_EXCL), closing the symlink-following
  overwrite primitive on `.tmp.$$` sibling paths.
- **Low**: prompt deletion scoped to success (CODE=3/5 retry reuses the
  prompt per the documented policy); selftest now asserts
  `ast_edit`/`task`/`hub` denies as well.

## 1.0.8 — 2026-09-22

### Fixed (external omp review round-6 follow-up)

- **High — pidfile added to the sandbox deny set**: the pidfile was the one
  contract artifact still writable by the reviewer (`git diff --output=
  <pidfile> HEAD`), letting a steered review forge the liveness state that
  `--resume` trusts (false CODE=3 for a running review + bookkeeping
  destruction). `PID_FILE` is now a literal deny in the sandbox profile.
- **High — resume trusts only numeric pids**: an unparseable pidfile is
  treated as untrusted (die CODE=2) instead of falling through to the
  completion classification.
- **Medium — adversarially-named untracked files can no longer hide**: the
  untracked list is NUL-delimited (`ls-files -z` + `read -d ''`); failures
  are counted and surfaced as `SKIPPED=<n>` in the export status line
  instead of being swallowed by `|| true`. Verified: a file named `a"b.txt`
  lands in the exported diff.
- **Medium — pidfile lifecycle is claim-scoped**: the owner update writes
  via tmp+`mv` (atomic, never-empty invariant preserved) and the cleanup
  tail removes pid/overlay/state/prompt only when the pidfile still holds
  this invocation's claim — a newer run for the same rid is no longer
  clobbered.
- **Low — export writes via tmp+`mv`**: a re-export for the same
  deterministic rid no longer tears the diff a concurrent reviewer reads.
- **Low**: empty `--diff-paths` CSV elements are filtered (trailing comma
  no longer dies `CODE=6` with an empty pathspec); `--export-diff` no
  longer requires the omp CLI (preflight moved below the export branch);
  empty unborn-repo export emits a well-formed `DIFFBYTES=0` status line;
  `--tag` documented as required on `--resume` (rid includes tag); SKILL.md
  documents the canonical-repo-path rid derivation; yolo ISO token aligned
  to `prompt-only (yolo)`.

## 1.0.7 — 2026-09-22

### Fixed (external omp review round-5 follow-up)

- **High — resume success path**: `prompt_file_abs` was only assigned in the
  launch branch; the resume fall-through tail hit it under `set -u` and
  aborted before emitting any `CODE=` line, so the documented CODE=4 →
  `--resume` continuation could never return CODE=0. The variable is now
  initialized with the other defaults (cleanup compares safely).
- **High — sandbox literals canonicalized**: the contract-artifact denies
  were keyed to the raw `$TMPDIR` spelling (`/var/folders/...`), while SBPL
  matches kernel-resolved paths (`/private/var/...`) — five of six literal
  denies were inert and the `git --output=` forging vector remained open.
  `tmp_dir` is now canonicalized once via `cd && pwd -P` (the sibling kimi
  runner does the same for exactly this reason).
- **Medium — untracked append honors `--diff-paths`**: the untracked pass
  previously re-derived its file list from the repo root, silently
  re-injecting everything the host had scoped out (the documented remedy
  for oversized prompts). The pathspecs now scope both passes.
- **Low — unborn-repo export**: a fresh `git init` + files (no commits) no
  longer dies CODE=6 on `git diff HEAD`; the tracked pass is skipped and
  the untracked append produces the diff (fixed a top-level `git -- <path>`
  form when pathspecs were appended to an empty argv).
- **Low**: `--no-tools` docs updated (it now carries the overlay +
  `--no-extensions` too).

## 1.0.6 — 2026-09-22

### Fixed (external omp review round-4 follow-up; rounds 3–4 reviewed stale
diffs, the items below are the ones NOT already covered by 1.0.5)

- **HIGH — completion-contract forging closed**: the sandbox profile now
  denies writes to the runner's own contract artifacts (result/err/state/
  overlay/profile/prompt literal paths) in addition to WORKSPACE/GIT_DIR/
  SKILL_DIR — previously a steered reviewer could stamp a line-start
  `Verdict: APPROVE` into its own result file with one allow-listed
  `git diff --output=<result-file> HEAD` (the rid is derivable from the
  DIFF_PATH disclosed in the prompt, and the anchored classifier accepts a
  diff-context leading space).
- **no-tools arm hardened**: `--no-tools` now also passes `--no-extensions`
  and the generated overlay (provider/extension strip) — previously the
  repo's `.omp/hooks|tools|extensions` would still load as code in the mode
  SKILL.md prescribes for untrusted repos.
- **--yolo unwrapped by design**: the write sandbox no longer wraps yolo
  runs (documented UNRESTRICTED; ISO=prompt-only (yolo)).
- **empty pidfile no longer locks the rid**: an empty/unparseable pidfile is
  treated as stale and reclaimed via the atomic mv path (a live claim is
  always created with content, so empty can never be live).
- Prompt template and allowlist docs now list the refused metacharacter
  classes (`>`, `|`, `--`, `--output=`); kimi runner SBPL comment restored
  to the order-sensitive rationale (placement after the broad read allow is
  load-bearing under SBPL last-match-wins).

## 1.0.5 — 2026-09-22

### Fixed (external omp review round-3 follow-up)

- **CRITICAL — reviewed-repo omp config/code surface neutralized**: the
  reviewed repo's `.omp/config.yml` deep-merges over the overlay (a shipped
  `tools.approval.eval: allow` would survive), and `.omp/hooks|tools|
  extensions` are code loaded into the reviewer process. The generated
  overlay now sets `disabledProviders` (strips the repo's settings/hooks/
  tools/extensions/MCP discovery) and `disabledExtensions` (project
  AGENTS.md/CLAUDE.md/GEMINI.md context files), adds `eval`/`task`/`hub`
  denies, and Guarded passes `--no-extensions`.
- **MEDIUM — untracked-only changes**: `HEAD-dirty` export appends new-file
  diffs for untracked paths (`git diff --no-index /dev/null <file>`); an
  agent-authored untracked-only change no longer degrades to CODE=6
  empty-diff.
- **LOW batch**: deny key renamed `new-context` → `new_context` (registered
  tool name; `notebook` dropped — no such kernel tool), resume-mode
  completion no longer leaks the launch's sandbox profile (owned-path
  derivation moved before the mode branches), `--wait-seconds` normalized
  base-10 (`09` no longer aborts as an octal literal), `--diff-paths`
  outside `--export-diff` rejected (CODE=2) instead of silently ignored,
  rid empty-tag encoding documented (`SHA256("repo|ref")` — no trailing
  separator) with a selftest assertion, success-path cleanup removes the
  prompt actually used, `git show <rev> -- <path>` allowlist limitation
  documented (workaround `git show <rev>:<path>`), smoke recipe extended to
  assert `ISO=` + the `--output=` probe.

## 1.0.4 — 2026-09-22

### Fixed (external omp review round-2 follow-up)

- **CRITICAL — sandbox-exec write boundary**: the bash allowlist is a string
  prefix match and cannot express "no file-writing options"; git's
  `--output=<file>` writes arbitrary files from allow-listed commands with
  no shell redirection (reproduced live by the omp reviewer under this very
  overlay). Guarded mode now wraps the omp process in a `sandbox-exec`
  profile denying `file-write*` under the reviewed repo (WORKSPACE), its
  git dir, and this skill dir. A usability probe degrades honestly to
  `ISO=prompt-only` on hosts that deny `sandbox_apply` at the process level
  (observed on WorkBuddy 2026-09-22) — on such hosts only the overlay layer
  is active and untrusted repositories must use `--no-tools` (SKILL.md).
- **MEDIUM — stale-claim reclaim**: the stale pidfile is reclaimed by an
  atomic `mv` (single winner) instead of `rm` + recreate, closing the
  two-reclaimer window that could delete a live claim.
- **MEDIUM — resume orphaning**: `--resume` invoked after the process
  finished within the CODE=4 gap now falls through to the completion
  classification (CODE=0/3/5 with RESULTFILE=) instead of dying CODE=2.
- **LOW**: real child exit status in `EXITED=` (launch mode; `?` on resume),
  `umask 077` for all review artifacts, `guarded_extra_flags()` extracted
  with selftest assertions (always-ask, --no-lsp/--no-rules/--no-skills,
  extended denies, catch-all), SKILL.md parameter table and contract
  updated, bash 3.2 empty-array expansion fixed (`${arr[@]+...}` idiom).

## 1.0.3 — 2026-09-22

### Fixed (external omp review follow-up, verdict REQUEST_CHANGES → fixes)

The first live omp review of this skill (Guarded, 18.1.18) found that the
Guarded mode relied on `--approval-mode write` + a five-tool deny list, while
omp auto-approves **every** read/write-tier tool in `write` mode — leaving
LSP, manage_skill, new-context, learn, and MCP tools outside the deny
enumeration, and letting a reviewed repo ship an `lsp.json` whose
attacker-chosen command is spawned by a read-tier (auto-approved) LSP action.

- **CRITICAL/HIGH — Guarded policy inverted**: default mode is now
  `--approval-mode always-ask` (read tier auto-approved; every write/exec-tier
  call fail-closed in print mode) + `--no-lsp --no-rules --no-skills`, with
  the overlay deny list extended to `lsp`, `manage_skill`, `new-context`,
  `learn` (the five original denies kept as belt-and-braces). This closes the
  repo-supplied `lsp.json` RCE vector, the LSP write-tier rename/applyEdit
  mutation vector, and the MCP/manage_skill write surface.
- **MEDIUM — reviewed-repo context injection**: `--no-rules --no-skills` now
  default in Guarded and no-tools modes, so repo-supplied AGENTS.md /
  CLAUDE.md instruction files cannot steer the reviewer into emitting a
  fabricated line-start `Verdict:` that satisfies the completion contract.
  Residual documented: the host's CODE=0 attests "omp emitted a verdict",
  not "an independent reviewer did" — result-content injection remains a
  host-side discipline (SKILL.md 结果处理/注入免疫).
- **LOW — tmp_dir misdiagnosis**: unwritable temp directory now fails
  preflight (`CODE=2`, clear message) instead of masquerading as
  `CODE=7 already_running`.
- **LOW — --tools equals-form**: `--tools "$list"` uses the space form like
  every other flag (the `=`-form was the one untested argv path).
- **LOW — die() status line**: `die` now emits `CODE=<exit> REASON=error` on
  stdout before exiting, so hosts parsing the documented status line see
  contract output on preflight/export/resume failure paths too.
- Live re-smoke (smoke3, omp 18.1.18, new Guarded semantics): plain
  `git status --short` allowed, `write` tool hard-denied, probe file never
  created, VERDICT=APPROVE — the allowlist keeps working under always-ask.

## 1.0.2 — 2026-09-22

### Fixed (claude recheck round 2 follow-up)

- **N1 (P2) empty-claim window**: the pidfile is now created atomically WITH
  content (`set -o noclobber; printf '%s|%s\n' "$$" "$launched_at"`), so a
  concurrent loser can never observe an empty claim and delete the live
  claimant's pidfile. Empty/unparseable existing pidfile fails closed to
  `CODE=7 REASON=already_running PID=unknown`. The winner overwrites the
  pidfile with the omp child pid after launch (owner update).
- **N2 (P2) diff_file symlink guard**: export-mode `diff_file` and the
  export stderr capture path now refuse pre-existing symlinks.
- **N3 (P3)**: `--no-tools --tools X` rejected as mutually exclusive.
- **N4 (P3)**: `--export-diff` / `--resume` exclusivity is flag-based
  (`resume_seen`), no longer order-dependent.
- **O1 (P3)**: rid derivation concatenates the repo path, so `--repo`
  paths containing `|` are now rejected alongside `--ref`/`--tag`.
- **Export diagnostics**: git stderr for `--export-diff` failures is
  captured to `<tmp>/omp-review-<rid>-export-err.txt` and surfaced in the
  `CODE=6` status line (ERRFILE=).
- Cosmetic: `[\*[:space:]]` → `[*[:space:]]` (no literal backslash in ERE
  bracket class).

## 1.0.1 — 2026-09-22

### Fixed (external claude review follow-up, verdict NEEDS_ATTENTION → fixes)

- **P1 redirection bypass**: probed live per the review's gate procedure —
  `git status --short > file`, `git show HEAD:a.txt > file`,
  `git diff HEAD > file` are all denied pre-execution by omp 18.1.18
  (`Blocked by bash pattern: *`; no probe file created, verified by glob and
  reads from inside the reviewer). Redirection does not match the
  trailing-`*` allow patterns; documented as machine-verified evidence in
  SKILL.md. No code change required.
- **P2 completion contract**: `classify_result` and the verdict extraction
  are now anchored to line start (`^[\*[:space:]]*Verdict: ?(APPROVE|
  REQUEST_CHANGES)`) so the prompt template's own mid-sentence mention of
  "Verdict: APPROVE" can never fabricate a CODE=0.
- **P2 single-flight TOCTOU**: pidfile is now claimed with `set -o
  noclobber` (atomic create), with stale-claim reclaim and a second
  liveness check before `CODE=7`.
- **P2 temp-path symlinks**: the runner refuses to follow pre-existing
  symlinks for all five runner-owned temp paths (rid is derivable from
  public inputs; the `/tmp` fallback is world-writable).
- **P3 batch**: `--ref`/`--tag` reject `|` (rid-concatenation ambiguity);
  `--yolo`/`--no-tools`/`--tools`/`--bash-allow` exclusivity enforced;
  `--wait-seconds` numerically validated; `--export-diff` pathspecs pass
  through `--`; `--resume` no longer requires the prompt file and reads the
  original `launched=` timestamp from the state sidecar for ELAPSED;
  `--export-diff` + `--resume` rejected as mutually exclusive; documented
  the two-line launch output, the `--bash-allow` YAML quoting caveat, and
  the git-config execution-vector trust assumption (untrusted repos →
  `--no-tools`).

### Verification (2026-09-22)

- `bash -n` clean under both bash 5 (PATH) and system bash 3.2 (`/bin/bash`).
- `--selftest` 11/11 under both runtimes.
- Guarded live smoke #2 (corrected `bash.patterns` schema): plain
  `git status --short` allowed, `git rev-parse` allowed, `write` tool
  hard-denied, compound command denied, VERDICT=APPROVE, OMPV echoed.
- Redirection probe (Guarded): three redirect attempts denied
  pre-execution; zero files created.

## 1.0.0 — 2026-09-22

### Added

- Initial macOS bash port of the Windows skill
  (`agent-docs/skills/ask-omp-review` v1.16.9, pwsh 7). Core contract aligned:
  - deterministic run-id: `rid = SHA256("repo|ref[:|tag]")[:10]` (shasum);
  - single-flight protection (`CODE=7 already_running` → `--resume`);
  - diff export to `<repo>/.git/review-cache/omp-review-<rid>.diff`
    (`CODE=6` on git failure / empty diff, DIFFBYTES < 64 guard);
  - Guarded mode: `--approval-mode write` + generated `--config` overlay
    (edit/write/ast_edit/notebook/memory_edit deny, bash read-only-git
    allowlist with catch-all deny, `--bash-allow` extras);
  - bounded event-driven wait (`--wait-seconds`, default 540 < 600s host tool
    cap) with `CODE=4` → `--resume` continuation;
  - completion contract: `0` result+Verdict / `3` empty / `5` no-verdict;
  - `--selftest` static assertions (rid determinism, overlay invariants,
    completion-contract classification), no network.
- SKILL.md: per-invocation workflow (diff export → prompt file → Guarded
  launch → bounded wait → contract), failure classification table, non-git
  variant, result-handling discipline (hallucination filter, injection
  immunity, drift triage), Host Compatibility Notes.

### Differences from the Windows port (deliberate)

- Runtime: bash (macOS system bash 3.2 compatible) instead of pwsh 7; no
  PS 5.1/CP936/UTF-16 pitfalls to guard against.
- Process liveness via `kill -0` instead of PID|StartTimeTicks dual
  fingerprint + Get-Process: no `ps`/`pgrep` dependency, so hosts whose
  command sandbox denies process introspection (observed: WorkBuddy
  2026-09-21) can still drive the full runner.
- Not ported in 1.0.0 (candidates for later): FP/FP8 diff content
  fingerprint + `<ArchiveDir>` durable-artifact lifecycle (AGENTS.md
  "Durable review artifact" policy on the Windows side), `-SelfTest -Live`
  networked smoke suite, codegraph allowlist extension, pid-reuse owner
  fingerprinting (bash `kill -0` on a reused PID could in principle misjudge
  liveness; mitigated by same-session usage and short rid lifetimes).
- Default bash allowlist is read-only git recon only (the Windows default
  includes `mvn test`; add it explicitly via `--bash-allow` when wanted).
