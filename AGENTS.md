# AGENTS.md

## Project

`derivation.el` — Live buffer and variable derivation. Think live, memoized pipelines between Emacs buffers or from one variable to another.

## Code

- `derivation.el` — single-file library, ~400 lines.
- `derivation-tests.el` — ERT tests.
- `flake.nix` — Nix flake for non-interactive batch testing (`nix build` runs the ERT suite; the devShell provides Emacs). The package version derives from `self.lastModifiedDate` (last commit date, sliced to `0-unstable-YYYY-MM-DD`); pure evaluation has no timestamp, so it falls back to `0-unstable-1970-01-01`. Never hand-edit the date.

## Conventions

- Open work items live in the **Open work items** section at the end of this file; before starting work, read it and pick up unfinished items. When you finish an item, delete it from the section (no crossing out).
- `derivation-make-deriver` takes `(command frombuf tobuf &rest args)`. `command` is a string (external program) or function. Extra `args` are passed to the external command. Now a thin wrapper over `derivation--make-buffer-deriver`.
- `derivation-make-var-deriver` takes `(func fromvar tovar)`. `func` is called with the value of `fromvar`. The result is assigned to `tovar` via `set`. Auto-registered via `derivation-register` (no buffer lifecycle). Thin wrapper over `derivation--memoizer`.
- `derivation-make-section-filter` takes `(predicate frombuf tobuf)`. `predicate` is called with each child of `magit-root-section` in `frombuf`; matching section text is copied to `tobuf`. Uses `slot-value` + `with-no-warnings` to avoid a hard magit-section compile-time dependency. Thin wrapper over `derivation--make-buffer-deriver`.
- `derivation-make` takes `(pull-fn push-fn &optional stamp-fn)` — the generic data-deriver primitive. `pull-fn` returns the derived data (a pure scan of global state); `push-fn` renders it and is responsible for selecting its target buffer. Memoized on `equal` of the data (`copy-tree`ed); with `stamp-fn` the pull is skipped while the stamp is unchanged. Does NOT self-register — callers pass the result to `derivation-register`.
- `derivation-make-input` takes `(pull &optional stamp name)` and returns a `derivation-input`: a memoized live value. `derivation-input-value` pulls only when the stamp changed or after `derivation-input-invalidate`; with no stamp the input pulls once, then only on invalidation. A stamp is a zero-arg function returning an `equal`-comparable value. Stamps compose via `derivation-stamp-or`; helpers: `derivation-stamp-always`, `derivation-stamp-mtime`, `derivation-stamp-files`, `derivation-stamp-git` (HEAD + tracked dirt, untracked files ignored like Nix flakes). Errors signal `derivation--failed`, keep the last good value, and land in `derivation-input-error`.
- `derivation-make-command-input` takes `(command &key directory environment stamp transform name)`: one-shot `call-process`, stdout captured, default `transform` is `string-trim`, nonzero exit signals `derivation--failed` with stderr. Synchronous. Use it for one-shot value producers such as `nix build --no-out-link`.
- `derivation-make-process` takes keyword args `:name :command :directory :environment :auto-restart :backoff :stop-signal :stop-timeout :debounce` and returns a `derivation-process` handle. `:command` is a non-empty list; its elements, `:directory`, and `(VAR . VALUE)` environment values may be strings, `derivation-input`s or functions. Resolution records the inputs it reads. SPEC = resolved `(:command ... :program ... :directory ... :environment ...)`, compared with `equal`: a change asks the old child to stop (STOP-SIGNAL now, SIGKILL after STOP-TIMEOUT) and the sentinel starts the replacement after the old child exits. `:program` holds the executable's truename, inode, size and mtime (`derivation--program-stamp`), so replacing or retargeting the binary restarts the child even when argv stays the same. The deriver self-registers and reconciles on `derivation-run-hooks`; `derivation-unregister` accepts the handle. Output goes to a hidden log buffer with `derivation--source`/mode-line support; killing that buffer unregisters. Auto-restart backs off 0.5/1/2/5s and resets after a stable run. STATUS `:stopping` means the exit is in flight.
- Environment entries resolve to `"VAR=VALUE"` strings or `(VAR)` for unset. The spec stores only these entries; the inherited `process-environment` joins at start, so ambient env changes do not trigger restarts.
- `derivation--memoizer` also exposes a VALUE closure (dirty check + sync + last data), so `derivation-input` reuses the primitive instead of a second memo implementation. An input folds a generation counter plus its stamp into the memo stamp, so manual invalidation works even with a stamp.
- `derivation-make-tabulated` takes `(entries-fn format &key name sort-key)` — a live `tabulated-list-mode` buffer. `entries-fn` returns `tabulated-list-entries` rows; the deriver polls on the runner schedule and re-renders only on change. Non-idempotent: each call makes a fresh buffer (`generate-new-buffer-name`) and registers a fresh deriver that unregisters when the buffer is killed; renders once at creation; returns the buffer. Errors keep the last good table and set `derivation--error`.
- `derivation--source` is `(SOURCE . RUN-FN)`: SOURCE is a buffer or a string label (data derivations have no source buffer); RUN-FN recomputes the target bypassing memoization (used by `derivation-rerun` and `revert-buffer`). Both `derivation-mode-line` and `derivation-jump-to-source` handle either SOURCE form.
- `derivation--memoizer` is the single memoization primitive (returns a `derivation--memo` struct of DIRTYP/SYNC/FORCE/VALUE closures). `derivation-make` uses SYNC; the three constructors do too; `derivation-input` uses VALUE. `derivation--make-buffer-deriver` builds a tick-stamped buffer deriver on top and wires `derivation--install-target-hooks` + kill hooks. A PULL-FN may signal `derivation--failed` to abort without committing the stamp (retry on the next pass); FORCE bypasses memoization for rerun/revert.
- `derivation-rerun` collects the upstream chain by `push`-ing while walking current → upstream, so the list is already upstream → downstream; it iterates it directly (no `reverse`). Running downstream-first would let a target transform read a stale intermediate. `derivation-run-hooks` converges via its fixpoint loop instead.
- Buffer derivers (`derivation-make-deriver`, `derivation-make-section-filter`) install `buffer-stale-function` and `revert-buffer-function` buffer-locally in the target via `derivation--install-target-hooks`. This lets the built-in `auto-revert-mode` (or `global-auto-revert-mode` + `global-auto-revert-non-file-buffers`) drive re-derivation instead of the idle timer. Staleness is the cheap tick check; `revert-buffer` runs the inner transform directly (bypassing memoization, like `derivation-rerun`).
- `derivation--walk-tree` traverses the section tree, reading each node's EIEIO `children` slot directly (the only concrete tree is magit's `magit-section`). No `cl-defgeneric`; add one only if a second concrete tree type appears.
- Memoization: buffer derivers and section filters key on `buffer-chars-modified-tick`; variable derivers on `equal` of the value with `(copy-tree cur-val t)` (in-place mutation detection). All funnel through `derivation--memoizer` (no per-constructor `last-tick` slot, no GC fragility). A `let` rebinding to an `equal` value does not recompute.
- Both sinks write via `derivation--replace-contents`, which uses `replace-region-contents` (Emacs 31+; falls back to `replace-buffer-contents`) so point, markers, and `window-start` survive updates and `after-change-functions` fire (font-lock etc. see the change). It preserves the buffer's modified state rather than using `with-silent-modifications`.
- Cleanup is deterministic: `derivation-unregister` runs each record's cleanup fn. `derivation--register-kill-hooks` runs the cleanup from the buffer-local `kill-buffer-hook` too (idempotent), so killing a source/target frees the deriver's watcher/hidden buffers. `derivation-make-deriver` allocates its hidden stderr buffer lazily (first failed string command) and kills it on unregister/buffer kill; `derivation-make-var-deriver` decrements the `derivation--var-watch-table` refcount and removes the variable watcher at zero. `derivation--run-one-pass` snapshots `derivation--storage` with `copy-sequence`.
- Derivations registered via `derivation-register` (constructors self-register); stored in `derivation--storage` records `(DERIVER . CLEANUP-FN)`; run via `derivation-run-hooks` to a fixpoint. Errors are isolated per-deriver (one broken deriver does not abort others). Buffer derivers auto-unregister when their source or target buffer is killed via a buffer-local `kill-buffer-hook`.
- Tests use temporary buffers, skip on missing executables.

## Error handling

- On command failure (non-zero exit) or function error, the target buffer keeps its last good output.
- The memo tick advances only on success, so a failed command is retried on the next pass (not just after the next source edit).
- stderr from failed commands is captured in a hidden buffer (space-prefixed name).
- `derivation--error` is set buffer-locally in the target on failure; the mode-line indicator shows "⟳!" in error face.

## Known limitations (current session)

- Buffer source derivers poll via idle timer, or — opt-in — via `auto-revert-mode` using the installed `buffer-stale-function`. Long-running commands block Emacs (sync `call-process-region`). `derivation-make-command-input` runs synchronously too, so an expensive command blocks Emacs during the pull.
- `derivation-unregister` and `derivation-process-stop` return before the child exits; the child can outlive the call by up to `:stop-timeout`, then the SIGKILL timer and sentinel finish the state change. `derivation--process-start` is synchronous (`make-process`). Program identity touches the filesystem (and TRAMP) on every process pass.
- In-place mutations on vectors and hash tables are not caught by `equal` (vectors are handled by `copy-tree cur-val t`; hash tables are not).
- `derivation--storage` is a double-dash private var; the public API is `derivation-register`/`derivation-unregister`.  Rename the var to `derivation-storage` eventually.

## Namespace migration (done)

The rename from the old `make-*` names landed in the pre-0.1 history
(commit `69b2dcf`); the old names are gone:

- `make-deriver` → `derivation-make-deriver`
- `make-var-deriver` → `derivation-make-var-deriver`
- `make-section-filter` → `derivation-make-section-filter`
- `run-hooks-derivation` → `derivation-run-hooks`
- `memoize-by-buffer-contents--wrap-buf` → deleted

## Ground-up redesign notes (for a future session)

### Unify the stamp abstraction

Status: DONE. `derivation--memoizer` is the single primitive (a `derivation--memo` struct of DIRTYP/SYNC/FORCE closures); `derivation-make` and all three original constructors wrap it. `derivation--make-buffer-deriver` adds the tick stamp + target hooks + kill hooks for the two buffer constructors. See `derivation--memoizer`.

Buffer source stamps on `buffer-chars-modified-tick`; the variable deriver stamps on nothing (polls) and memoizes on `equal` of the value; the section filter stamps on the source tick. A PULL-FN may signal `derivation--failed` to abort without committing the stamp; FORCE bypasses memoization for rerun/revert.

### First-class inputs (started)

`derivation-input` landed: memoized live values with cheap `equal` stamps and manual invalidation, plus the stamp constructors. The buffer and variable constructors still carry ad-hoc stamps; the process sink is the first intended consumer.

### Process sink

Done: `derivation-make-process` reconciles a child against a spec resolved from inputs. Async stop (STOP-SIGNAL now, SIGKILL timer, sentinel starts the replacement), program identity and debounce landed. Remaining: an `:on-change` hook for SIGHUP reloads instead of restarts.

### Push, not poll

Use `after-change-functions` (or `track-changes` library, available since Emacs 30.1) + a debounce timer per source buffer, running dependents in topological order. Even without topology, a fixpoint loop solves the N-cycle pipeline convergence issue.

The `buffer-stale-function` / `revert-buffer-function` integration is the first step toward letting `auto-revert-mode` replace the package's idle timer for buffer derivers. Data derivers (`derivation-make`, `derivation-make-tabulated`) have no cheap stamp; migrating them onto the same hooks would require a polling staleness check or a real change notification.

### Async buffer commands

Buffer derivers and `derivation-make-command-input` still run external commands via `call-process-region`/`call-process`, which freezes the UI on slow commands. Use `make-process` + sentinel with a generation counter to discard stale results. Process start/stop already async.

### replace-buffer-contents

Done: both sinks write via `derivation--replace-contents`, which uses `replace-region-contents` (Emacs 31+) with a `replace-buffer-contents` fallback, preserving point, markers, window scroll, and firing `after-change-functions`.

### Explicit lifecycle

`derivation-register` / `derivation-unregister` plus `kill-buffer-hook` cleanup. The `make-finalizer` refcounting for variable watchers is clever but GC-timing-dependent behavior caused the old weak-key hash-table bug. Deterministic cleanup is better.

## Open work items

Numbered work items for this project.  **Remove items entirely once finished** (no crossing out).

### API / design

1. **Async buffer commands.** `derivation-make-deriver` and `derivation-make-command-input` still run external commands via `call-process-region`/`call-process`, which freezes the UI on slow commands. Use `make-process` + sentinel with a generation counter to discard stale results. Process start/stop already async.

2. **Wire inputs into existing derivers.** `derivation--make-buffer-deriver` and `derivation-make-var-deriver` still build stamps by hand; a buffer input and a variable input would unify them under `derivation-input` (buffer tick, watcher generation).

3. **Reload hook for processes.** Add `:on-change (old-spec new-spec)` returning `:restart` or nil, so a server can get SIGHUP instead of a full restart.

### Cleanup

4. **Test `derivation-mode-line-form-evaluates` tests implementation, not behavior.** It `eval`s `(cadr derivation-mode-line)` directly. A rendering-based test is impossible in the batch suite: `format-mode-line` is a deliberate no-op when `noninteractive` (see `Fformat_mode_line` in xdisp.c), so the rendered string can't be checked under `emacs --batch`. Either keep the eval-based test or move the suite to a display-backed runner.

5. **Minor: stderr capture.** `with-temp-buffer` + `insert-file-contents` for stderr could be a single `insert-file-contents` into a reused buffer.
