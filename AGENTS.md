# AGENTS.md — derivation.el

## Purpose

`derivation.el`: Emacs Lisp library for live buffer and variable derivation.
Builds memoized pipelines between Emacs buffers, and from one variable to another,
and reconciles long-running child processes against live values. Emacs 31 or
newer, for `replace-region-contents`. License: AGPL-3.0-or-later.

## Layout

- `derivation.el` — single-file library, about 400 lines.
- `derivation-tests.el` — ERT suite, 98 tests.
- `flake.nix` — flake for non-interactive batch testing. `nix build` runs the
  ERT suite and the formatting check. The devShell provides Emacs.
- `flake.lock` — pinned inputs.

## Build and test

- `nix build` — package plus ERT suite plus the treefmt check. Gate for a commit.
- `nix flake check` — the same checks.
- `nix develop` — dev shell with a real Emacs.
- `nix fmt` — treefmt.
- `emacs --batch -L . -l derivation-tests.el -f
  ert-run-tests-batch-and-exit` — run the suite directly.

Do not hand-edit the version. The flake derives `0-unstable-YYYY-MM-DD` from
`self.lastModifiedDate`, which comes from the last commit date. Pure evaluation
carries no timestamp, so it falls back to `0-unstable-1970-01-01`.

## Architecture

### Constructors

- `derivation-make-deriver` takes `(command frombuf tobuf &rest args)`. `command`
  is a string for an external program, which runs asynchronously, or a function,
  which runs synchronously. Extra `args` go to the external command. A string
  command feeds the source text through a seekable temp file, starts through
  `make-process`, and discards a result whose source tick went stale. Wraps
  `derivation--make-buffer-deriver`.
- `derivation-make-var-deriver` takes `(func fromvar tovar)`. `func` receives the
  value of `fromvar`, and the result lands in `tovar` through `set`. It
  self-registers through `derivation-register`, with no buffer lifecycle. Wraps a
  polling `derivation-input`: the pull reads `fromvar` and the push sets `tovar`,
  and a missing stamp makes every pass pull, so an in-place mutation still
  reaches the `equal` check. The variable watcher exists for refcounted
  registration alone.
- `derivation-make-section-filter` takes `(predicate frombuf tobuf)`. `predicate`
  receives each child of `magit-root-section` in `frombuf`, and the matching
  section text goes to `tobuf`. Uses `slot-value` plus `with-no-warnings` to avoid
  a hard magit-section compile-time dependency. Wraps
  `derivation--make-buffer-deriver` with a tick-stamped input.
- `derivation-make` takes `(pull-fn push-fn &optional stamp-fn)`, the generic
  data-deriver primitive. `pull-fn` returns derived data from a pure scan of
  global state, and `push-fn` renders it and selects its target buffer. Memoized
  on `equal` of `copy-tree`ed data. With `stamp-fn`, the pull is skipped while the
  stamp holds. Does not self-register, so a caller passes the result to
  `derivation-register`.
- `derivation-make-tabulated` takes `(entries-fn format &key name sort-key)` and
  returns a live `tabulated-list-mode` buffer. `entries-fn` returns
  `tabulated-list-entries` rows. The deriver polls on the runner schedule and
  re-renders on change alone. Not idempotent: each call makes a fresh buffer
  through `generate-new-buffer-name`, registers a fresh deriver that unregisters
  when the buffer dies, renders once, and returns the buffer. An error keeps the
  last good table and sets `derivation--error`.

### Inputs and stamps

- `derivation-make-input` takes `(pull &optional stamp name)` and returns a
  memoized live value. `derivation-input-value` pulls only when the stamp changed
  or after `derivation-input-invalidate`. With no stamp it pulls once and then on
  invalidation alone. A stamp is a zero-argument function returning an
  `equal`-comparable value. Stamps compose through `derivation-stamp-or`.
  Helpers: `derivation-stamp-always`, `derivation-stamp-mtime`,
  `derivation-stamp-files`, and `derivation-stamp-git`, which reads HEAD plus
  tracked dirt and ignores untracked files like Nix flakes. An error signals
  `derivation--failed`, keeps the last good value, and lands in
  `derivation-input-error`.
- `derivation-make-buffer-input` takes `(buffer &optional name)` and stamps on
  `buffer-chars-modified-tick`.
- `derivation-make-command-input` takes `(command &key directory environment stamp
  transform name)`. Runs an asynchronous `make-process`, captures stdout, defaults
  `transform` to `string-trim`, and signals `derivation--failed` with stderr on a
  nonzero exit. `derivation-input-value` signals `derivation--pending` while the
  command runs, and `derivation-input-wait` blocks for the value. Environment
  values must be strings. Use it for a one-shot producer such as
  `nix build --no-out-link`.
- `derivation--retry-delay` (1s by default) spaces retries of a failed async
  command. A failed buffer command or command input starts a new job only after
  the delay, unless the source tick or input stamp changed. `derivation-rerun` and
  `derivation-input-invalidate` reset the delay.
- `derivation--source` is `(SOURCE . RUN-FN)`. SOURCE is a buffer or a string
  label, since a data derivation has no source buffer. RUN-FN recomputes the
  target and bypasses memoization, which `derivation-rerun` and `revert-buffer`
  use. `derivation-mode-line` and `derivation-jump-to-source` handle either SOURCE
  form.

### Processes

- `derivation-make-process` takes `:name :command :directory :environment
  :auto-restart :backoff :stop-signal :stop-timeout :debounce :on-change` and
  returns a `derivation-process` handle. `:command` is a non-empty list. Its
  elements, `:directory` and the `(VAR . VALUE)` environment values may be
  strings, `derivation-input`s or functions. Resolution records the inputs it
  reads. SPEC, the resolved `(:command ... :program ... :directory ...
  :environment ...)`, compares with `equal`. A change asks the old child to stop,
  sends STOP-SIGNAL now and SIGKILL after STOP-TIMEOUT, and the sentinel starts
  the replacement after the old child exits.
- `:on-change (old new)` runs first while the child lives. A nil return keeps the
  child and records the new spec, which reloads in place. `:restart` or `t` stops
  and starts. Any other value errors and leaves the old spec.
- `:program` holds the executable truename, inode, size and mtime through
  `derivation--program-stamp`, so replacing or retargeting the binary restarts the
  child even when argv stays the same.
- The process deriver self-registers and reconciles on `derivation-run-hooks`.
  `derivation-unregister` accepts the handle. Output goes to a hidden log buffer
  with `derivation--source` and mode-line support, and killing that buffer
  unregisters. Auto-restart backs off 0.5, 1, 2 and 5 seconds, and resets after a
  stable run. STATUS `:stopping` means the exit is in flight.
- An environment entry resolves to a `"VAR=VALUE"` string, or to `(VAR)` for an
  unset variable. The spec stores these entries alone, and the inherited
  `process-environment` joins at start, so an ambient env change triggers no
  restart.

### Memoization and lifecycle

- `derivation--memoizer` is the single memoization primitive. It returns a
  `derivation--memo` struct of DIRTYP, SYNC, FORCE and VALUE closures.
  `derivation-make` uses SYNC, the constructors use it too, and
  `derivation-input` uses VALUE. An input folds a generation counter plus its
  stamp into the memo stamp, so manual invalidation works even with a stamp.
- `derivation--make-input` is the shared input constructor, taking PULL, PUSH,
  STAMP, NAME and POLL. `derivation-make-input` passes `ignore` as PUSH. A PULL-FN
  may signal `derivation--failed` to abort without committing the stamp, which
  retries on the next pass, or `derivation--pending` while asynchronous work runs,
  which retries with no error. FORCE bypasses memoization for rerun and revert.
- `derivation--make-buffer-deriver` takes a `derivation-input`, whose memo
  supplies DIRTYP, SYNC and FORCE, and wires `derivation--install-target-hooks`
  plus kill hooks around it.
- Buffer derivers stamp on `buffer-chars-modified-tick`. A variable deriver polls
  and memoizes on `equal` of the value with `(copy-tree cur-val t)`, which
  catches an in-place mutation. A `let` rebinding to an `equal` value does not
  recompute.
- `derivation-rerun` collects the upstream chain by pushing while it walks from
  current to upstream, so the list already runs upstream to downstream and it
  iterates that directly with no `reverse`. A downstream-first run would let a
  target transform read a stale intermediate. `derivation-run-hooks` converges
  through a fixpoint loop instead.
- Buffer derivers install `buffer-stale-function` and `revert-buffer-function`
  buffer-locally in the target through `derivation--install-target-hooks`. That
  lets `auto-revert-mode`, or `global-auto-revert-mode` with
  `global-auto-revert-non-file-buffers`, drive re-derivation instead of the idle
  timer. Staleness stays the cheap tick check, and `revert-buffer` runs the inner
  transform directly.
- `derivation--walk-tree` traverses the section tree and reads each node's EIEIO
  `children` slot directly, because the only concrete tree type is magit's
  `magit-section`. No `cl-defgeneric`. Add one only if a second concrete tree type
  appears.
- Both sinks write through `derivation--replace-contents`, which uses
  `replace-region-contents` with a `replace-buffer-contents` fallback, so point,
  markers and `window-start` survive and `after-change-functions` fire. It
  preserves the buffer modified state instead of using
  `with-silent-modifications`.
- Cleanup is deterministic. `derivation-unregister` runs each record's cleanup
  function. `derivation--register-kill-hooks` runs the cleanup from the
  buffer-local `kill-buffer-hook` too, which is idempotent, so killing a source or
  a target frees the watcher and the hidden buffers. `derivation-make-deriver`
  keeps a lazy hidden stderr buffer for a failed function command and a per-job
  stdout, stderr and stdin trio for an async string command, and cleanup kills
  them. `derivation-make-var-deriver` decrements the `derivation--var-watch-table`
  refcount and removes the watcher at zero. `derivation--run-one-pass` snapshots
  `derivation--storage` with `copy-sequence`.
- `derivation--storage` records `(DERIVER . CLEANUP-FN)`, fills from
  `derivation-register`, and runs through `derivation-run-hooks` to a fixpoint. An
  error stays isolated per deriver.

## Rules

- On a non-zero exit or a function error, keep the last good output in the target
  buffer. Advance the memo tick on success alone, so a failed command retries on
  the next pass and not only after the next source edit.
- Capture stderr of a failed command in a hidden, space-prefixed buffer. Set
  `derivation--error` buffer-locally in the target and show `⟳!` in the error face
  on the mode line.
- Mark a value helper that depends on its arguments alone with
  `(declare (pure t) (side-effect-free t))`, as `derivation--command-environment`
  does. Mark a helper that reads global or object state and writes nothing with
  `(declare (side-effect-free t))` alone, as `derivation--source-label`,
  `derivation--process-environment`, `derivation-process-live-p` and
  `derivation-process-exit-status` do.
- Never mark a state-mutating function, a predicate-calling tree walk, or a
  closure constructor with a mutable capture.
- A derivation registers through `derivation-register`. The constructors
  self-register, with the exception of `derivation-make` and
  `derivation-make-input`.
- Buffer derivers auto-unregister when their source or target buffer dies,
  through a buffer-local `kill-buffer-hook`.
- Read the Open work section before you start, and pick up an unfinished item.
  Delete an item once it finishes. Do not cross it out.

## Conventions

- Prefix public names with `derivation-` and private names with `derivation--`.
  The public API stays `derivation-register` and `derivation-unregister`, so
  `derivation--storage` keeps its private name until a rename lands.
- Tests use temporary buffers and skip when an executable is missing.
- Write a test beside every behaviour change. The suite holds 98 tests in one
  file.

## Open work

### Known limitations

- A buffer source deriver polls through the idle timer, or through
  `auto-revert-mode` with the installed `buffer-stale-function` when opted in.
  External string commands and command inputs run asynchronously, so a slow
  command no longer freezes Emacs. An async result lands on the next
  `derivation-run-hooks` pass, or on `derivation-input-wait` for a command input.
- A failed async command retries after `derivation--retry-delay`, 1s by default,
  unless the source tick or the input stamp changed. An abandoned command-input
  job holds its hidden buffers until a read or a process exit.
- `derivation-unregister` and `derivation-process-stop` return before the child
  exits. The child can outlive the call by up to `:stop-timeout`, and then the
  SIGKILL timer and the sentinel finish the state change.
  `derivation--process-start` is synchronous. Program identity touches the file
  system, and TRAMP, on every process pass.
- An in-place mutation on a vector or a hash table escapes the `equal` check.
  Vectors survive through `copy-tree cur-val t`. Hash tables do not.
- `format-mode-line` is a deliberate no-op under `emacs --batch`, so the suite
  checks the `derivation-mode-line` form through `eval` and not through rendered
  output. A rendering test needs a display-backed runner.
- `derivation--storage` keeps a double-dash name while the public API stays
  `derivation-register` and `derivation-unregister`. Rename it to
  `derivation-storage` eventually.

### Future redesign notes

- Unify the stamp abstraction. Done. `derivation--memoizer` is the single
  primitive. `derivation-make`, the three constructors and `derivation-input` all
  build on it, and `derivation--make-input` is the shared input constructor.
- First-class inputs. Done. `derivation-input` underpins every constructor.
- Process sink. Done. `derivation-make-process` reconciles a child against a spec
  resolved from inputs. Async stop, program identity, debounce and `:on-change`
  reloads landed.
- Push, not poll. Use `after-change-functions`, or the `track-changes` library
  available since Emacs 30.1, plus a debounce timer per source buffer, and run
  dependents in topological order. Even without topology, a fixpoint loop
  converges an N-cycle pipeline. The `buffer-stale-function` and
  `revert-buffer-function` integration is the first step toward letting
  `auto-revert-mode` replace the idle timer for buffer derivers. Data derivers
  (`derivation-make`, `derivation-make-tabulated`) carry no cheap stamp, so they
  need a polling staleness check or a real change notification.
- Async buffer commands. Done. `derivation--command` wraps `make-process` with a
  sentinel. A string command runs async, feeds stdin through a seekable temp file,
  discards a stale result, and spaces a failed retry through
  `derivation--retry-delay`.
- `replace-buffer-contents`. Done. See `derivation--replace-contents` above.
- Explicit lifecycle. `derivation-register` and `derivation-unregister` plus
  `kill-buffer-hook` cleanup. The `make-finalizer` refcounting for variable
  watchers looked clever, but its GC-timing dependence caused the old weak-key
  hash-table bug. Deterministic cleanup wins.

### Open work items

None. The namespace migration landed in the pre-0.1 history (commit `69b2dcf`).
The old `make-*` names are gone: `make-deriver` became `derivation-make-deriver`,
`make-var-deriver` became `derivation-make-var-deriver`, `make-section-filter`
became `derivation-make-section-filter`, `run-hooks-derivation` became
`derivation-run-hooks`, and `memoize-by-buffer-contents--wrap-buf` is deleted.
