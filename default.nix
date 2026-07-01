{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
  emacs ? pkgs.emacs,
  emacsPackages ? emacs.pkgs,
  melpaBuild ? emacsPackages.melpaBuild,
}:

melpaBuild (finalAttrs: {
  pname = "derivation";
  version = "0.1.0";
  src = lib.cleanSource ./.;

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
    description = "Live buffer derivation via external commands";
    longDescription = ''
      A minor Emacs Lisp library for creating derived buffers:
      pipe the content of one buffer through an external command
      into another buffer.  The result is memoized per source-buffer
      tick, so you can call it often without performance impact.
    '';
    license = lib.licenses.agpl3Plus;
    homepage = "https://github.com/nagy/derivation";
    maintainers = with lib.maintainers; [ nagy ];
    platforms = lib.platforms.unix;
  };
})
