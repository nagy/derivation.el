# AGENTS.md

## Project

`derivation.el` — Live buffer derivation via external commands. Think live, memoized shell pipelines between Emacs buffers.

## Code

- `derivation.el` — single-file library, ~135 lines.
- `derivation-tests.el` — ERT tests.
- `default.nix` — Nix build for non-interactive batch testing.

## Conventions

- `make-deriver` takes `(command frombuf tobuf &rest args)`. `command` is a string (external program) or function. Extra `args` are passed to the external command.
- Memoization keyed on `(source-buffer . buffer-chars-modified-tick)`.
- Derivations stored in `derivation--storage` list; run via `run-hooks-derivation`.
- Tests use temporary buffers, skip on missing executables.
