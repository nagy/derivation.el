# AGENTS.md

## Project

`derivation.el` — Live buffer and variable derivation. Think live, memoized pipelines between Emacs buffers or from one variable to another.

## Code

- `derivation.el` — single-file library, ~225 lines.
- `derivation-tests.el` — ERT tests.
- `default.nix` — Nix build for non-interactive batch testing.

## Conventions

- `make-deriver` takes `(command frombuf tobuf &rest args)`. `command` is a string (external program) or function. Extra `args` are passed to the external command.
- `make-var-deriver` takes `(func fromvar tovar)`. `func` is called with the value of `fromvar`. The result is assigned to `tovar` via `set`.
- Memoization keyed on `(source-buffer . buffer-chars-modified-tick)` for buffers, or a hybrid of variable watchers + `equal` for variables.
- Derivations stored in `derivation--storage` list; run via `run-hooks-derivation`.
- Tests use temporary buffers, skip on missing executables.
