{
  description = "Live buffer and variable derivation (Emacs package)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      # One nixpkgs closure, no duplicates.
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      flake-parts,
      nixpkgs,
      treefmt-nix,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } (
      top@{ self, ... }:
      {
        # Emacs packages are pure Elisp: no ELF binaries, so evaluate on
        # every Linux arch (and darwin if the deps exist there).
        systems = [
          "x86_64-linux"
          "aarch64-linux"
        ];

        perSystem =
          {
            system,
            pkgs,
            lib,
            config,
            ...
          }:
          let
            inherit (pkgs.emacsPackages) melpaBuild;
            # treefmt drives nixfmt via `nix fmt` — never run formatters
            # standalone on flake files.
            treefmt = treefmt-nix.lib.evalModule pkgs {
              projectRootFile = "flake.nix";
              programs.nixfmt.enable = true;
            };
            # Nix rejects versions Nixpkgs cannot parse. Convention for
            # unreleased packages: <upstream-version>-unstable-<YYYY-MM-DD>.
            # lastModifiedDate is the last commit date of the flake repo
            # (format YYYYMMDDHHMMSS), so slice it into a date.
            # Pure evaluation has no lastModifiedDate (null): fall back to
            # the epoch. A dirty tree does NOT move the date.
            src-version =
              let
                last = self.lastModifiedDate or null;
              in
              if last == null then
                "0-unstable-1970-01-01"
              else
                "0-unstable-${builtins.substring 0 4 last}-${builtins.substring 4 2 last}-${builtins.substring 6 2 last}";
          in
          {
            packages.derivation = melpaBuild {
              pname = "derivation";
              version = src-version;

              src = lib.cleanSource ./.;

              # Elisp dependencies from the Package-Requires header that
              # already exist in nixpkgs. The package is self-contained,
              # so nothing to add here.

              # Byte-compilation warnings fail the build. Keep it on: it is
              # the cheapest lint the package will ever get. Silence only
              # genuinely noisy third-party warnings, never your own code.
              turnCompilationWarningToError = true;

              checkPhase = ''
                runHook preCheck
                emacs --batch -L . \
                  -l derivation-tests.el \
                  -f ert-run-tests-batch-and-exit
                runHook postCheck
              '';

              doCheck = true;

              meta = {
                description = "Live buffer and variable derivation via memoized pipelines";
                # 2–5 sentences: what it does, how (which Emacs primitives /
                # external services), and any notable modes of operation.
                longDescription = ''
                  A minor Emacs Lisp library for creating derived buffers, live
                  variable derivations and long-running child processes: pipe the
                  content of one buffer through an external command or function
                  into another buffer, derive one variable's value from another's,
                  or restart a server whenever the live values that build its
                  command, working directory or environment change.

                  Results are memoized per source-buffer tick, variable watcher
                  generation or input stamp, so derivations can run often without
                  performance impact. External commands run asynchronously and
                  stale results are discarded. On command failure the target
                  keeps its last good output; errors are shown via a mode-line
                  indicator.
                '';
                # Read the license from the file header — Elisp packages
                # conventionally declare it after ";;; Code:".
                license = lib.licenses.agpl3Plus;
                homepage = "https://github.com/nagy/derivation";
                maintainers = with lib.maintainers; [ nagy ];
                platforms = lib.platforms.unix;
              };
            };

            packages.default = config.packages.derivation;

            formatter = treefmt.config.build.wrapper;
            checks.formatting = treefmt.config.build.check self;

            devShells.default = pkgs.mkShell {
              # A real Emacs for interactive testing of the package under
              # development: nix develop && emacs -L . -l derivation-tests.el
              packages = [ pkgs.emacs ];
            };
          };
      }
    );
}
