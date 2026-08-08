# AGENTS.md

## Project

`derivation.el` — Live buffer and variable derivation. Think live, memoized pipelines between Emacs buffers or from one variable to another.

## Code

- `derivation.el` — single-file library, ~400 lines.
- `derivation-tests.el` — ERT tests.
- `default.nix` — Nix build for non-interactive batch testing.

## Conventions

- Open work items live in the **Open work items** section at the end of this file; before starting work, read it and pick up unfinished items. When you finish an item, delete it from the section (no crossing out).
- `derivation-make-deriver` takes `(command frombuf tobuf &rest args)`. `command` is a string (external program) or function. Extra `args` are passed to the external command.
- `derivation-make-var-deriver` takes `(func fromvar tovar)`. `func` is called with the value of `fromvar`. The result is assigned to `tovar` via `set`. Auto-registered via `derivation-register` (no buffer lifecycle).
- `derivation-make-section-filter` takes `(predicate frombuf tobuf)`. `predicate` is called with each child of `magit-root-section` in `frombuf`; matching section text is copied to `tobuf`. Uses `slot-value` + `with-no-warnings` to avoid a hard magit-section compile-time dependency.
- `derivation-make` takes `(pull-fn push-fn &optional stamp-fn)` — the generic data-deriver primitive. `pull-fn` returns the derived data (a pure scan of global state); `push-fn` renders it and is responsible for selecting its target buffer. Memoized on `equal` of the data (`copy-tree`ed); with `stamp-fn` the pull is skipped while the stamp is unchanged. Does NOT self-register — callers pass the result to `derivation-register`.
- `derivation-make-tabulated` takes `(entries-fn format &key name sort-key)` — a live `tabulated-list-mode` buffer. `entries-fn` returns `tabulated-list-entries` rows; the deriver polls on the runner schedule and re-renders only on change. Non-idempotent: each call makes a fresh buffer (`generate-new-buffer-name`) and registers a fresh deriver that unregisters when the buffer is killed; renders once at creation; returns the buffer. Errors keep the last good table and set `derivation--error`.
- `derivation--source` is `(SOURCE . INNER-FN)`: SOURCE is a buffer or a string label (data derivations have no source buffer); both `derivation-mode-line` and `derivation-jump-to-source` handle either.
- `derivation--node-children` is a `cl-defgeneric` dispatching tree traversal. New deriver types (map.el, seq.el) add `cl-defmethod`s here without changing the walker.
- Memoization is a single `last-tick` slot per deriver closure (no hash table, no GC fragility). Buffer derivers and section filters key on `buffer-chars-modified-tick`. Variable derivers use a hybrid of variable watcher generation counter + `equal` value comparison with `(copy-tree cur-val t)` for in-place mutation detection.
- Derivations registered via `derivation-register` (constructors self-register); stored in `derivation--storage` records `(DERIVER . CLEANUP-FN)`; run via `derivation-run-hooks` to a fixpoint. Errors are isolated per-deriver (one broken deriver does not abort others). Buffer derivers auto-unregister when their source or target buffer is killed via a buffer-local `kill-buffer-hook`.
- Tests use temporary buffers, skip on missing executables.

## Error handling

- On command failure (non-zero exit) or function error, the target buffer keeps its last good output.
- stderr from failed commands is captured in a hidden buffer (space-prefixed name).
- `derivation--error` is set buffer-locally in the target on failure; the mode-line indicator shows "⟳!" in error face.

## Known limitations (current session)

- Buffer source derivers poll via idle timer. Long-running commands block Emacs (sync `call-process-region`).
- In-place mutations on vectors and hash tables are not caught by `equal` (vectors are handled by `copy-tree cur-val t`; hash tables are not).
- `derivation--storage` is a double-dash private var; the public API is `derivation-register`/`derivation-unregister`.  Rename the var to `derivation-storage` eventually.

## Namespace migration TODO

Old names (still present as aliases needed by existing users):
- `make-deriver` → `derivation-make-deriver`
- `make-var-deriver` → `derivation-make-var-deriver`
- `make-section-filter` → `derivation-make-section-filter`
- `run-hooks-derivation` → `derivation-run-hooks`
- `memoize-by-buffer-contents--wrap-buf` → deleted

## Ground-up redesign notes (for a future session)

### Unify the stamp abstraction

Status: `derivation-make` (pull-fn, push-fn, optional stamp-fn) exists as the generic primitive, and `derivation-make-tabulated` (entries-fn, format, &key name sort-key) is its first specialization — a data-deriver with no stamp that polls and memoizes on `equal` of the data. The three original constructors are not yet migrated; tracked in the Open work items section, item 6.

Buffer-tick memoization and var-watcher+equal memoization are the same pattern: `(last-stamp, pull-fn, push-fn)`:

```elisp
(defun derivation-make (pull-fn push-fn &optional stamp-fn)
  (let ((last-stamp 'derivation--unset)
        (last-data 'derivation--unset))
    (lambda ()
      (let* ((poll (null stamp-fn))
             (stamp (unless poll (funcall stamp-fn)))
             (dirty (or poll
                        (eq last-stamp 'derivation--unset)
                        (not (equal stamp last-stamp)))))
        (when dirty
          (setq last-stamp stamp)
          (let ((data (funcall pull-fn)))
            (unless (equal data last-data)
              (setq last-data (copy-tree data t))
              (funcall push-fn data)
              t)))))))
```

Buffer source = stamp-fn returns `(buf . tick)`. Var source = stamp-fn returns `(gen . value)`. Section filter = tick + predicate. All three current constructors become ~5-line wrappers.

### Push, not poll

Use `after-change-functions` (or `track-changes` library, available since Emacs 30.1) + a debounce timer per source buffer, running dependents in topological order. Even without topology, a fixpoint loop solves the N-cycle pipeline convergence issue.

### Async processes

`make-process` + sentinel with a generation counter to discard stale results. `call-process-region` freezes the UI on every keystroke-then-idle for slow commands.

### replace-buffer-contents

In the sink instead of erase+insert — preserves point, markers, and window scroll in visible preview buffers (the core live-preview scenario).

### Explicit lifecycle

`derivation-register` / `derivation-unregister` plus `kill-buffer-hook` cleanup. The `make-finalizer` refcounting for variable watchers is clever but GC-timing-dependent behavior caused the old weak-key hash-table bug. Deterministic cleanup is better.

## Open work items

Numbered work items for this project.  **Remove items entirely once finished** (no crossing out).

### API / design

1. **Drop the `cl-defgeneric` tree walk.** `derivation--node-children` is speculative generality (map.el, seq.el deriver types that don't exist yet) that adds a soft EIEIO dependency and a `with-no-warnings` slot access. Introduce the generic only when a second concrete tree appears.

2. **Sink should use `replace-buffer-contents`.** `with-silent-modifications` + `erase-buffer` + `insert` suppresses `after-change-functions` and makes point/markers/window scroll jump in visible preview buffers. `replace-buffer-contents` preserves point, markers, and window-start (and undo).

3. **Async processes.** `make-process` + sentinel with a generation counter to discard stale results. `call-process-region` freezes the UI on every keystroke-then-idle for slow commands.

### Cleanup

4. **Test `derivation-mode-line-form-evaluates` tests implementation, not behavior.** It `eval`s `(cadr derivation-mode-line)` directly. A rendering-based test is impossible in the batch suite: `format-mode-line` is a deliberate no-op when `noninteractive` (see `Fformat_mode_line` in xdisp.c), so the rendered string can't be checked under `emacs --batch`. Either keep the eval-based test or move the suite to a display-backed runner.

5. **Minor: stderr capture.** `with-temp-buffer` + `insert-file-contents` for stderr could be a single `insert-file-contents` into a reused buffer.

6. **Migrate the three constructors onto `derivation-make`.** `derivation-make-deriver` (content pipeline), `derivation-make-var-deriver`, and `derivation-make-section-filter` should become thin wrappers around `derivation-make` with the appropriate stamp (buffer tick / watcher generation), replacing three copies of the memoization pattern with the unified one. Each becomes ~5 lines.
