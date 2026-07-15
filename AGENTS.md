# AGENTS.md

## Project

`derivation.el` — Live buffer and variable derivation. Think live, memoized pipelines between Emacs buffers or from one variable to another.

## Code

- `derivation.el` — single-file library, ~310 lines.
- `derivation-tests.el` — ERT tests.
- `default.nix` — Nix build for non-interactive batch testing.

## Conventions

- `make-deriver` takes `(command frombuf tobuf &rest args)`. `command` is a string (external program) or function. Extra `args` are passed to the external command.
- `make-var-deriver` takes `(func fromvar tovar)`. `func` is called with the value of `fromvar`. The result is assigned to `tovar` via `set`. Cleanup via `make-finalizer`.
- `make-section-filter` takes `(predicate frombuf tobuf)`. `predicate` is called with each child of `magit-root-section` in `frombuf`; matching section text is copied to `tobuf`. Uses `slot-value` + `with-no-warnings` to avoid a hard magit-section compile-time dependency.
- `derivation--node-children` is a `cl-defgeneric` dispatching tree traversal. New deriver types (map.el, seq.el) add `cl-defmethod`s here without changing the walker.
- Memoization keyed on `(source-buffer . buffer-chars-modified-tick)` for buffers, or a hybrid of variable watchers + `equal` for variables.
- Derivations stored in `derivation--storage` list; run via `run-hooks-derivation`.
- Tests use temporary buffers, skip on missing executables.
