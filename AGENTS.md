# AGENTS.md

## Project

`derivation.el` — Live buffer and variable derivation. Think live, memoized pipelines between Emacs buffers or from one variable to another.

## Code

- `derivation.el` — single-file library, ~400 lines.
- `derivation-tests.el` — ERT tests.
- `default.nix` — Nix build for non-interactive batch testing.

## Conventions

- `derivation-make-deriver` takes `(command frombuf tobuf &rest args)`. `command` is a string (external program) or function. Extra `args` are passed to the external command.
- `derivation-make-var-deriver` takes `(func fromvar tovar)`. `func` is called with the value of `fromvar`. The result is assigned to `tovar` via `set`. Cleanup via `make-finalizer`.
- `derivation-make-section-filter` takes `(predicate frombuf tobuf)`. `predicate` is called with each child of `magit-root-section` in `frombuf`; matching section text is copied to `tobuf`. Uses `slot-value` + `with-no-warnings` to avoid a hard magit-section compile-time dependency.
- `derivation--node-children` is a `cl-defgeneric` dispatching tree traversal. New deriver types (map.el, seq.el) add `cl-defmethod`s here without changing the walker.
- Memoization is a single `last-tick` slot per deriver closure (no hash table, no GC fragility). Buffer derivers and section filters key on `buffer-chars-modified-tick`. Variable derivers use a hybrid of variable watcher generation counter + `equal` value comparison with `(copy-tree cur-val t)` for in-place mutation detection.
- Derivations stored in `derivation--storage` list; run via `derivation-run-hooks`. Errors are isolated per-deriver (one broken deriver does not abort others).
- Tests use temporary buffers, skip on missing executables.

## Error handling

- On command failure (non-zero exit) or function error, the target buffer keeps its last good output.
- stderr from failed commands is captured in a hidden buffer (space-prefixed name).
- `derivation--error` is set buffer-locally in the target on failure; the mode-line indicator shows "⟳!" in error face.

## Known limitations (current session)

- Buffer source derivers poll via idle timer. Long-running commands block Emacs (sync `call-process-region`).
- Pipelines (A→B→C) need N idle cycles to fully converge because `last-tick` per deriver means each stage advances one tick per run.
- Section filter visits the root node in addition to children, which differs from the docstring's "each child section" claim. A predicate matching the root duplicates the whole buffer text.
- In-place mutations on vectors and hash tables are not caught by `equal` (vectors are handled by `copy-tree cur-val t`; hash tables are not).
- `kill-buffer-hook` cleanup not implemented — dead buffers are handled by `buffer-live-p` checks, but derivers for dead buffers stay in `derivation--storage` forever.
- `derivation--storage` is a double-dash private var but is the documented public entry point. Rename to `derivation-storage` (or better: provide `derivation-register`/`derivation-unregister`).

## Namespace migration TODO

Old names (still present as aliases needed by existing users):
- `make-deriver` → `derivation-make-deriver`
- `make-var-deriver` → `derivation-make-var-deriver`
- `make-section-filter` → `derivation-make-section-filter`
- `run-hooks-derivation` → `derivation-run-hooks`
- `memoize-by-buffer-contents--wrap-buf` → deleted

## Ground-up redesign notes (for a future session)

### Unify the stamp abstraction

Buffer-tick memoization and var-watcher+equal memoization are the same pattern: `(last-stamp, pull-fn, push-fn)`:

```elisp
(defun derivation-make (stamp-fn pull-fn push-fn)
  (let ((last 'derivation--unset))
    (lambda ()
      (let ((stamp (funcall stamp-fn)))
        (unless (equal stamp last)
          (setq last stamp)
          (funcall push-fn (funcall pull-fn)))))))
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
