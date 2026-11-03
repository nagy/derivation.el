# AGENTS.md

## Project

`derivation.el` — Live buffer and variable derivation. Think live, memoized pipelines between Emacs buffers or from one variable to another.

## Code

- `derivation.el` — single-file library, ~400 lines.
- `derivation-tests.el` — ERT tests.
- `flake.nix` — Nix flake for non-interactive batch testing (`nix build` runs the ERT suite; the devShell provides Emacs). The package version derives from `self.lastModifiedDate` (last commit date, sliced to `0-unstable-YYYY-MM-DD`); pure evaluation has no timestamp, so it falls back to `0-unstable-1970-01-01`. Never hand-edit the date.

## Conventions

- Open work items live in the **Open work items** section at the end of this file; before starting work, read it and pick up unfinished items. When you finish an item, delete it from the section (no crossing out).
- `derivation-make-deriver` takes `(command frombuf tobuf &rest args)`. `command` is a string (external program, asynchronous) or function (synchronous). Extra `args` are passed to the external command. String commands feed the source text through a seekable temp file, start via `make-process`, and discard results whose source tick went stale. Thin wrapper over `derivation--make-buffer-deriver` (async strings pass RESET-FN + cleanup).
- `derivation-make-var-deriver` takes `(func fromvar tovar)`. `func` is called with the value of `fromvar`. The result is assigned to `tovar` via `set`. Auto-registered via `derivation-register` (no buffer lifecycle). Thin wrapper over a polling `derivation-input`: the pull reads `fromvar`, the push sets `tovar`, and no stamp means every pass pulls so in-place mutations still reach the `equal` check. The variable watcher exists for refcounted registration only.
- `derivation-make-section-filter` takes `(predicate frombuf tobuf)`. `predicate` is called with each child of `magit-root-section` in `frombuf`; matching section text is copied to `tobuf`. Uses `slot-value` + `with-no-warnings` to avoid a hard magit-section compile-time dependency. Thin wrapper over `derivation--make-buffer-deriver` with a tick-stamped input.
- `derivation-make` takes `(pull-fn push-fn &optional stamp-fn)` — the generic data-deriver primitive. `pull-fn` returns the derived data (a pure scan of global state); `push-fn` renders it and is responsible for selecting its target buffer. Memoized on `equal` of the data (`copy-tree`ed); with `stamp-fn` the pull is skipped while the stamp is unchanged. Does NOT self-register — callers pass the result to `derivation-register`.
- `derivation-make-input` takes `(pull &optional stamp name)` and returns a `derivation-input`: a memoized live value. `derivation-input-value` pulls only when the stamp changed or after `derivation-input-invalidate`; with no stamp the input pulls once, then only on invalidation. A stamp is a zero-arg function returning an `equal`-comparable value. Stamps compose via `derivation-stamp-or`; helpers: `derivation-stamp-always`, `derivation-stamp-mtime`, `derivation-stamp-files`, `derivation-stamp-git` (HEAD + tracked dirt, untracked files ignored like Nix flakes). Errors signal `derivation--failed`, keep the last good value, and land in `derivation-input-error`.
- `derivation-make-buffer-input` takes `(buffer &optional name)` and returns a `derivation-input` for the buffer text, stamped on `buffer-chars-modified-tick`.
- `derivation-make-command-input` takes `(command &key directory environment stamp transform name)`: asynchronous `make-process`, stdout captured, default `transform` is `string-trim`, nonzero exit signals `derivation--failed` with stderr. `derivation-input-value` signals `derivation--pending` while the command runs; `derivation-input-wait` blocks for the value. Environment values must be strings. Use it for one-shot value producers such as `nix build --no-out-link`.
- `derivation--retry-delay` (default 1s) spaces retries of failed async commands. A failed buffer command or command input starts a new job only after the delay, unless the source tick or input stamp changed. `derivation-rerun` and `derivation-input-invalidate` reset the delay.
- `derivation-make-process` takes keyword args `:name :command :directory :environment :auto-restart :backoff :stop-signal :stop-timeout :debounce :on-change` and returns a `derivation-process` handle. `:command` is a non-empty list; its elements, `:directory`, and `(VAR . VALUE)` environment values may be strings, `derivation-input`s or functions. Resolution records the inputs it reads. SPEC = resolved `(:command ... :program ... :directory ... :environment ...)`, compared with `equal`: a change asks the old child to stop (STOP-SIGNAL now, SIGKILL after STOP-TIMEOUT) and the sentinel starts the replacement after the old child exits. `:on-change (old new)` runs first while the child lives: nil keeps the child and records the new spec (reload in place), `:restart`/t stops and starts, other values error and leave the old spec. `:program` holds the executable's truename, inode, size and mtime (`derivation--program-stamp`), so replacing or retargeting the binary restarts the child even when argv stays the same. The deriver self-registers and reconciles on `derivation-run-hooks`; `derivation-unregister` accepts the handle. Output goes to a hidden log buffer with `derivation--source`/mode-line support; killing that buffer unregisters. Auto-restart backs off 0.5/1/2/5s and resets after a stable run. STATUS `:stopping` means the exit is in flight.
- Environment entries resolve to `"VAR=VALUE"` strings or `(VAR)` for unset. The spec stores only these entries; the inherited `process-environment` joins at start, so ambient env changes do not trigger restarts.
- `derivation--memoizer` also exposes a VALUE closure (dirty check + sync + last data), so `derivation-input` reuses the primitive instead of a second memo implementation. An input folds a generation counter plus its stamp into the memo stamp, so manual invalidation works even with a stamp.
- `derivation-make-tabulated` takes `(entries-fn format &key name sort-key)` — a live `tabulated-list-mode` buffer. `entries-fn` returns `tabulated-list-entries` rows; the deriver polls on the runner schedule and re-renders only on change. Non-idempotent: each call makes a fresh buffer (`generate-new-buffer-name`) and registers a fresh deriver that unregisters when the buffer is killed; renders once at creation; returns the buffer. Errors keep the last good table and set `derivation--error`.
- `derivation--source` is `(SOURCE . RUN-FN)`: SOURCE is a buffer or a string label (data derivations have no source buffer); RUN-FN recomputes the target bypassing memoization (used by `derivation-rerun` and `revert-buffer`). Both `derivation-mode-line` and `derivation-jump-to-source` handle either SOURCE form.
- `derivation--memoizer` is the single memoization primitive (returns a `derivation--memo` struct of DIRTYP/SYNC/FORCE/VALUE closures). `derivation-make` uses SYNC; the constructors do too; `derivation-input` uses VALUE. `derivation--make-buffer-deriver` takes a `derivation-input` (its memo supplies DIRTYP/SYNC/FORCE) and wires `derivation--install-target-hooks` + kill hooks around it. `derivation--make-input` is the shared input constructor (PULL/PUSH/STAMP/NAME/POLL); `derivation-make-input` passes `ignore` as PUSH. A PULL-FN may signal `derivation--failed` to abort without committing the stamp (retry on the next pass) or `derivation--pending` while asynchronous work runs (retry, no error). FORCE bypasses memoization for rerun/revert.
- `derivation-rerun` collects the upstream chain by `push`-ing while walking current → upstream, so the list is already upstream → downstream; it iterates it directly (no `reverse`). Running downstream-first would let a target transform read a stale intermediate. `derivation-run-hooks` converges via its fixpoint loop instead.
- Buffer derivers (`derivation-make-deriver`, `derivation-make-section-filter`) install `buffer-stale-function` and `revert-buffer-function` buffer-locally in the target via `derivation--install-target-hooks`. This lets the built-in `auto-revert-mode` (or `global-auto-revert-mode` + `global-auto-revert-non-file-buffers`) drive re-derivation instead of the idle timer. Staleness is the cheap tick check; `revert-buffer` runs the inner transform directly (bypassing memoization, like `derivation-rerun`).
- `derivation--walk-tree` traverses the section tree, reading each node's EIEIO `children` slot directly (the only concrete tree is magit's `magit-section`). No `cl-defgeneric`; add one only if a second concrete tree type appears.
- Memoization: buffer derivers and section filters use their input's stamp (`buffer-chars-modified-tick`); variable derivers use a polling input (`POLL` t) and `equal` of the value with `(copy-tree cur-val t)` (in-place mutation detection). All funnel through `derivation--memoizer` (no per-constructor `last-tick` slot, no GC fragility). A `let` rebinding to an `equal` value does not recompute.
- Both sinks write via `derivation--replace-contents`, which uses `replace-region-contents` (Emacs 31+; falls back to `replace-buffer-contents`) so point, markers, and `window-start` survive updates and `after-change-functions` fire (font-lock etc. see the change). It preserves the buffer's modified state rather than using `with-silent-modifications`.
- Cleanup is deterministic: `derivation-unregister` runs each record's cleanup fn. `derivation--register-kill-hooks` runs the cleanup from the buffer-local `kill-buffer-hook` too (idempotent), so killing a source/target frees the deriver's watcher/hidden buffers. `derivation-make-deriver` keeps a lazy hidden stderr buffer for failed *function* commands and a per-job stdout/stderr/stdin trio for async string commands; cleanup kills them. `derivation-make-var-deriver` decrements the `derivation--var-watch-table` refcount and removes the variable watcher at zero. `derivation--run-one-pass` snapshots `derivation--storage` with `copy-sequence`.
- Derivations registered via `derivation-register` (constructors self-register); stored in `derivation--storage` records `(DERIVER . CLEANUP-FN)`; run via `derivation-run-hooks` to a fixpoint. Errors are isolated per-deriver (one broken deriver does not abort others). Buffer derivers auto-unregister when their source or target buffer is killed via a buffer-local `kill-buffer-hook`.
- Tests use temporary buffers, skip on missing executables.
- Value helpers that depend only on their arguments carry `(declare (pure t) (side-effect-free t))` (`derivation--command-environment`). Helpers that read global or object state but write nothing carry `(declare (side-effect-free t))` only (`derivation--source-label`, `derivation--process-environment`, `derivation-process-live-p`, `derivation-process-exit-status`). Do not mark state-mutating functions, predicate-calling tree walks, or closure constructors with mutable captures.

## Error handling

- On command failure (non-zero exit) or function error, the target buffer keeps its last good output.
- The memo tick advances only on success, so a failed command is retried on the next pass (not just after the next source edit).
- stderr from failed commands is captured in a hidden buffer (space-prefixed name).
- `derivation--error` is set buffer-locally in the target on failure; the mode-line indicator shows "⟳!" in error face.

## Known limitations (current session)

- Buffer source derivers poll via idle timer, or — opt-in — via `auto-revert-mode` using the installed `buffer-stale-function`. External string commands and command inputs run asynchronously now, so slow commands no longer freeze Emacs. Async results land on the next `derivation-run-hooks` pass (or `derivation-input-wait` for command inputs).
- A failed async command retries after `derivation--retry-delay` (default 1s), unless the source tick or input stamp changed. An abandoned command-input job holds its hidden buffers until a read or process exit.
- `derivation-unregister` and `derivation-process-stop` return before the child exits; the child can outlive the call by up to `:stop-timeout`, then the SIGKILL timer and sentinel finish the state change. `derivation--process-start` is synchronous (`make-process`). Program identity touches the filesystem (and TRAMP) on every process pass.
- In-place mutations on vectors and hash tables are not caught by `equal` (vectors are handled by `copy-tree cur-val t`; hash tables are not).
- `format-mode-line` is a deliberate no-op under `emacs --batch`, so the suite tests the `derivation-mode-line` construct by `eval`, not rendered output. A display-backed runner would be needed for rendering tests.
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

Status: DONE. `derivation--memoizer` is the single primitive (a `derivation--memo` struct of DIRTYP/SYNC/FORCE/VALUE closures); `derivation-make`, the three constructors and `derivation-input` all build on it. `derivation--make-input` is the shared input constructor, and `derivation--make-buffer-deriver` wires target hooks + kill hooks around an input. A PULL-FN may signal `derivation--failed` or `derivation--pending`.

Buffer source stamps on `buffer-chars-modified-tick`; the variable deriver stamps on nothing (polls) and memoizes on `equal` of the value; the section filter stamps on the source tick. A PULL-FN may signal `derivation--failed` to abort without committing the stamp; FORCE bypasses memoization for rerun/revert.

### First-class inputs (done)

`derivation-input` underpins every constructor now: `derivation-make-input` (public values), `derivation-make-buffer-input`, the buffer/section derivers (tick-stamped inputs with a target-writing push), and the variable deriver (polling input with a `set` push).

### Process sink

Done: `derivation-make-process` reconciles a child against a spec resolved from inputs. Async stop, program identity, debounce and `:on-change` reloads landed.

### Push, not poll

Use `after-change-functions` (or `track-changes` library, available since Emacs 30.1) + a debounce timer per source buffer, running dependents in topological order. Even without topology, a fixpoint loop solves the N-cycle pipeline convergence issue.

The `buffer-stale-function` / `revert-buffer-function` integration is the first step toward letting `auto-revert-mode` replace the package's idle timer for buffer derivers. Data derivers (`derivation-make`, `derivation-make-tabulated`) have no cheap stamp; migrating them onto the same hooks would require a polling staleness check or a real change notification.

### Async buffer commands

Done: `derivation--command` wraps `make-process` with a sentinel.  String commands in `derivation-make-deriver` and `derivation-make-command-input` run async, feed stdin through a temp file (seekable), discard results whose tick went stale, and space failed retries with `derivation--retry-delay`.

### replace-buffer-contents

Done: both sinks write via `derivation--replace-contents`, which uses `replace-region-contents` (Emacs 31+) with a `replace-buffer-contents` fallback, preserving point, markers, window scroll, and firing `after-change-functions`.

### Explicit lifecycle

`derivation-register` / `derivation-unregister` plus `kill-buffer-hook` cleanup. The `make-finalizer` refcounting for variable watchers is clever but GC-timing-dependent behavior caused the old weak-key hash-table bug. Deterministic cleanup is better.

## Open work items

Numbered work items for this project.  **Remove items entirely once finished** (no crossing out).

No open work items.
