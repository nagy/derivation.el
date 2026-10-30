;;; derivation.el --- Live buffer and variable derivation -*- lexical-binding: t -*-

;; Copyright (C) 2026  Daniel Nagy

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with this file.  If not, see
;; <https://www.gnu.org/licenses/>.

;; Author: Daniel Nagy
;; Version: 0.1.0
;; Keywords: tools
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; `derivation' creates derived buffers and variables: buffers whose
;; content is the result of piping another buffer through an external
;; command, and variables whose value is derived from other variables
;; via an Elisp function.
;; Think of it as a live, memoized shell pipeline between buffers.
;;
;; Setup:
;;
;;   (require 'derivation)
;;
;;   ;; Derive *json-out* from foo.json by running `jq` on every change.
;;   (derivation-register (derivation-make-deriver
;;          "jq"                               ; command
;;          (get-buffer-create "foo.json")      ; source
;;          (get-buffer-create "*json-out*")    ; target
;;          "."                                 ; extra args to jq
;;          "-C"))
;;
;;   ;; Derive *yaml-out* from *json-out* (a pipeline of two buffers).
;;   (derivation-register (derivation-make-deriver
;;          "yq"
;;          (get-buffer-create "*json-out*")
;;          (get-buffer-create "*yaml-out*")
;;          "-p" "json" "-o" "yaml"))
;;
;;   ;; Derive *baz* from *foo* via `base64-encode-string'.
;;   (derivation-register (derivation-make-deriver
;;          #'base64-encode-string
;;          (get-buffer-create "*foo*")
;;          (get-buffer-create "*baz*")))
;;   ;; Derive variable `baz' from `foo' via `length'.
;;   (derivation-register (derivation-make-var-deriver #'length 'foo 'baz))
;;
;;   ;; A live value computed by a one-shot command.
;;   (defvar my-docs
;;     (derivation-make-command-input
;;      '("nix" "build" "--no-out-link" ".#cargo-docs")
;;      :directory "/path/to/project"
;;      :stamp (derivation-stamp-git "/path/to/project")))
;;   (derivation-input-value my-docs)        ; => "/nix/store/...-cargo-doc"
;;   (derivation-input-invalidate my-docs)   ; force a rebuild next read
;;
;;   ;; Run derivations on idle.
;;   (run-with-idle-timer 0.1 t #'derivation-run-hooks)
;;
;; Auto-revert integration:
;; Target buffers of buffer derivers (external command, Elisp function,
;; section filter) also get buffer-local `buffer-stale-function' and
;; `revert-buffer-function'.  Users can therefore drive them with the
;; built-in `auto-revert-mode' instead of the timer above.  For hidden
;; (space-prefixed) targets, set `global-auto-revert-non-file-buffers'.
;;
;; Because derivations are memoized, calling them repeatedly when the
;; source hasn't changed is a no-op — ideal for idle timers.
;;
;; Error handling:
;; When a command fails (non-zero exit), the target buffer keeps its
;; last good output.  stderr is captured in a hidden buffer, and the
;; mode-line indicator changes to show the error state.  When the source
;; is fixed, the derivation recovers automatically on the next run.

;;; Code:

(require 'cl-lib)
(require 'tabulated-list)

(defvar derivation--storage nil
  "List of (DERIVER . CLEANUP-FN) records, most recently registered first.
DERIVER is a function returned by `derivation-make-deriver',
`derivation-make-var-deriver' or `derivation-make-section-filter'.
CLEANUP-FN, when non-nil, uninstalls the deriver's kill-buffer hooks;
it is called by `derivation-unregister'.

Never manipulate this list directly: use `derivation-register' and
`derivation-unregister'.")

(defun derivation-register (deriver &optional cleanup)
  "Register DERIVER so `derivation-run-hooks' runs it.

CLEANUP is a function that uninstalls DERIVER's kill-buffer hooks
(see `derivation--register-kill-hooks').  It is optional for derivers
with no buffer lifecycle (e.g. variable derivers).

Returns DERIVER."
  (unless (functionp deriver)
    (error "derivation-register: DERIVER must be a function, got %S" deriver))
  (push (cons deriver cleanup) derivation--storage)
  deriver)

(defun derivation-unregister (deriver)
  "Remove DERIVER from `derivation--storage'.
Deriver records are also removed automatically when their source or
target buffer is killed; this is for manual teardown.

Returns non-nil if DERIVER was registered."
  (let ((removed (assq deriver derivation--storage)))
    (when removed
      (setq derivation--storage (delq removed derivation--storage))
      (when (cdr removed)
        (funcall (cdr removed))))
    removed))

(defun derivation--register-kill-hooks (deriver bufs)
  "Install a buffer-local `kill-buffer-hook' in each live buffer of BUFS.
The hook removes DERIVER's record from `derivation--storage' and runs
that record's cleanup function, so resources owned by the deriver are
released when a source or target buffer dies.

Returns a cleanup function that uninstalls the hooks; it is idempotent
and safe to call from within the hook itself."
  (let ((hook
         (lambda ()
           (let ((rec (assq deriver derivation--storage)))
             (when rec
               (setq derivation--storage (delq rec derivation--storage))
               (when (cdr rec)
                 (funcall (cdr rec))))))))
    (dolist (buf bufs)
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (add-hook 'kill-buffer-hook hook nil t))))
    (lambda ()
      (dolist (buf bufs)
        (when (buffer-live-p buf)
          (with-current-buffer buf
            (remove-hook 'kill-buffer-hook hook t)))))))

(defun derivation--replace-contents (text)
  "Replace the accessible text of the current buffer with TEXT.
Unlike `erase-buffer'+`insert', this edits only the differing regions
via `replace-region-contents' (falling back to
`replace-buffer-contents' before Emacs 31), so point, markers, and
`window-start' in visible targets do not jump, undo stays coherent,
and `after-change-functions' run (font-lock and friends see the
update).

Mirrors `with-silent-modifications' where it matters: the buffer's
modified state is preserved (the derivation is not a user edit).
Read-only is bypassed, as the previous sink did."
  (let ((inhibit-read-only t)
        (modified (buffer-modified-p))
        (src (generate-new-buffer " *derivation-sink*")))
    (unwind-protect
        (progn
          (with-current-buffer src (insert text))
          (if (fboundp 'replace-region-contents)
              (replace-region-contents (point-min) (point-max) src)
            (with-no-warnings (replace-buffer-contents src))))
      (kill-buffer src))
    (restore-buffer-modified-p modified)))

;;; Memoization primitive

(defconst derivation--unset (make-symbol "derivation--unset")
  "Sentinel distinguishing \"never run\" from any real value.")

;; Signal raised by a PULL-FN to abort a sync without committing the
;; stamp, so the next sync retries (used for failed commands).
(define-error 'derivation--failed "Derivation failed")

(cl-defstruct (derivation--memo (:constructor derivation--memo-create))
  "Memoization state for a PULL-FN/PUSH-FN pipeline.
DIRTYP, SYNC, FORCE and VALUE are closures; see `derivation--memoizer'."
  dirtyp sync force value)

(defun derivation--memoizer (pull-fn push-fn &optional stamp-fn)
  "Build memoization state for PULL-FN/PUSH-FN versioned by STAMP-FN.

Return a `derivation--memo' with three closures:

  DIRTYP  non-nil when the stamp changed since the last commit (always
          non-nil when STAMP-FN is nil: polling mode).
  SYNC    pull, commit the stamp, push when the data changed.  Returns
          non-nil when it pushed.
  FORCE   pull and push unconditionally, committing the stamp and the
          data (bypasses memoization; used by rerun/revert).

  VALUE   return the last pulled data, running SYNC first when the
          memo is dirty.  Used by `derivation-input'.

PULL-FN may signal `derivation--failed' to abort without committing the
stamp, so a later SYNC retries.  The signal propagates to the caller."
  (let ((last-stamp derivation--unset)
        (last-data derivation--unset))
    (cl-labels
        ((commit (data stamp)
           (setq last-stamp stamp)
           (unless (equal data last-data)
             (setq last-data (copy-tree data t))
             (funcall push-fn data)
             t))
         (dirtyp ()
           (or (null stamp-fn)
               (eq last-stamp derivation--unset)
               (not (equal (funcall stamp-fn) last-stamp))))
         (sync ()
           (let* ((poll (null stamp-fn))
                  (stamp (unless poll (funcall stamp-fn))))
             (when (or poll
                       (eq last-stamp derivation--unset)
                       (not (equal stamp last-stamp)))
               (commit (funcall pull-fn) stamp))))
         (force ()
           ;; Bypass memoization: re-render even when the data is
           ;; unchanged (rerun/revert must repair a tampered target).
           (let ((data (funcall pull-fn)))
             (setq last-stamp (and stamp-fn (funcall stamp-fn))
                   last-data (copy-tree data t))
             (funcall push-fn data)
             t))
         (value ()
           ;; SYNC already compares the stamp, so no DIRTYP pre-check:
           ;; that would call an expensive stamp twice per read.
           (sync)
           (unless (eq last-data derivation--unset) last-data)))
      (derivation--memo-create
       :dirtyp #'dirtyp :sync #'sync :force #'force :value #'value))))

;;; Live inputs and staleness stamps

;; A stamp is a zero-argument function returning an `equal'-comparable
;; value.  It answers "did anything change?" without doing the work
;; that an input's PULL-FN does.  Compose stamps with
;; `derivation-stamp-or'.

(cl-defstruct (derivation-input (:constructor derivation--input-create)
                                 (:copier nil))
  "A memoized live value with an explicit staleness STAMP.
PULL is called only when STAMP changed or after
`derivation-input-invalidate'.  MEMO holds the shared memoization
state (see `derivation--memoizer').  GENERATION counts manual
invalidations.  ERROR holds the last failure message."
  name pull stamp generation memo error)

;;;###autoload
(defun derivation-make-input (pull &optional stamp name)
  "Create a memoized live value computed by PULL.

PULL is called with no arguments and returns the value.  STAMP is a
zero-argument function returning an `equal'-comparable value: the
input pulls again only when STAMP changed.  With STAMP nil the input
pulls once and then only after `derivation-input-invalidate' — the
safe default for expensive pulls.  NAME is for display and debugging.

When PULL signals `derivation--failed', the last good value stays
cached and the signal propagates.  `derivation-input-value' records
the message in `derivation-input-error'.

See `derivation-stamp-or', `derivation-stamp-mtime',
`derivation-stamp-files', `derivation-stamp-git' and
`derivation-stamp-always' for stamp constructors."
  (unless (functionp pull)
    (error "derivation-make-input: PULL must be a function, got %S"
           (type-of pull)))
  (when (and stamp (not (functionp stamp)))
    (error "derivation-make-input: STAMP must be a function or nil, got %S"
           (type-of stamp)))
  (let ((input (derivation--input-create
                :name name :pull pull :stamp stamp :generation 0)))
    (setf (derivation-input-memo input)
          (derivation--memoizer
           pull #'ignore
           ;; The generation counter makes every input manually
           ;; invalidatable even when it carries a stamp.
           (lambda ()
             (list (derivation-input-generation input)
                   (and (derivation-input-stamp input)
                        (funcall (derivation-input-stamp input)))))))
    input))

(defun derivation-input-value (input)
  "Return the current value of INPUT, pulling again when stale.

When PULL fails, the last good value stays cached, the message lands
in `derivation-input-error', and the `derivation--failed' signal
propagates."
  (unless (derivation-input-p input)
    (error "derivation-input-value: not a derivation-input: %S" input))
  (condition-case err
      (prog1 (funcall (derivation--memo-value (derivation-input-memo input)))
        (setf (derivation-input-error input) nil))
    (derivation--failed
     (setf (derivation-input-error input)
           (or (cadr err) (error-message-string err)))
     (signal (car err) (cdr err)))))

(defun derivation-input-dirty-p (input)
  "Return non-nil when INPUT's stamp changed since the last pull."
  (unless (derivation-input-p input)
    (error "derivation-input-dirty-p: not a derivation-input: %S" input))
  (funcall (derivation--memo-dirtyp (derivation-input-memo input))))

(defun derivation-input-invalidate (input)
  "Mark INPUT stale.  The next `derivation-input-value' pulls again.

Returns INPUT, so calls chain."
  (unless (derivation-input-p input)
    (error "derivation-input-invalidate: not a derivation-input: %S" input))
  (cl-incf (derivation-input-generation input))
  input)

(defun derivation-stamp-always ()
  "Return a stamp that changes on every check (polling mode)."
  (let ((counter 0))
    (lambda () (cl-incf counter))))

(defun derivation-stamp-or (&rest stamps)
  "Return a stamp that changes when any of STAMPS changes.

STAMPS are zero-argument functions.  The result returns a list of
their values, so it is `equal'-comparable."
  (dolist (stamp stamps)
    (unless (functionp stamp)
      (error "derivation-stamp-or: not a stamp: %S" stamp)))
  (lambda () (mapcar #'funcall stamps)))

(defun derivation-stamp-mtime (file)
  "Return a stamp over FILE's modification time.

A missing FILE stamps as nil, so creating it counts as a change."
  (let ((file (expand-file-name file)))
    (lambda ()
      (let ((attrs (file-attributes file)))
        (and attrs (file-attribute-modification-time attrs))))))

(defun derivation-stamp-files (files)
  "Return a stamp over the modification times of FILES."
  (apply #'derivation-stamp-or (mapcar #'derivation-stamp-mtime files)))

(defun derivation--git-output (directory args)
  "Run git with ARGS in DIRECTORY.  Return output, or nil on failure."
  (with-temp-buffer
    (let* ((default-directory (file-name-as-directory
                               (expand-file-name directory)))
           (code (apply #'call-process "git" nil t nil args)))
      (when (zerop code)
        (buffer-string)))))

(defun derivation-stamp-git (directory)
  "Return a stamp over DIRECTORY's git HEAD and tracked modifications.

Untracked files are ignored, matching what Nix flakes see.  A
repository without commits stamps HEAD as nil."
  (unless (executable-find "git")
    (error "derivation-stamp-git: git executable not found"))
  (unless (file-directory-p directory)
    (error "derivation-stamp-git: not a directory: %s" directory))
  (let ((directory (file-name-as-directory (expand-file-name directory))))
    (lambda ()
      (list (derivation--git-output directory '("rev-parse" "--verify" "HEAD"))
            (derivation--git-output directory '("status" "--porcelain" "-uno"))))))

;;;###autoload
(cl-defun derivation-make-command-input (command &key directory environment
                                                 stamp transform name)
  "Create a live value from the stdout of a one-shot COMMAND.

COMMAND is a list (PROGRAM ARG...).  It runs synchronously via
`call-process'.  DIRECTORY is the working directory (default: the
`default-directory' at creation).  ENVIRONMENT is a list of
\"VAR=VALUE\" strings prepended to `process-environment', so it
overrides inherited variables.  TRANSFORM post-processes stdout
\(default `string-trim', which drops the trailing newline that most
commands print).  STAMP, NAME and error handling are as in
`derivation-make-input'.

On a non-zero exit the input signals `derivation--failed' with the
captured stderr (or an exit-status message when stderr is empty).

Use this for expensive value producers such as
\='(\"nix\" \"build\" \"--no-out-link\" \".#docs\").  Pair it with a cheap
STAMP so the command runs only when its inputs change."
  (unless (and (listp command) (stringp (car command)))
    (error "derivation-make-command-input: COMMAND must be (PROGRAM ARG...)"))
  (dolist (arg command)
    (unless (stringp arg)
      (error "derivation-make-command-input: COMMAND elements must be strings: %S"
             arg)))
  (let* ((directory (file-name-as-directory
                     (expand-file-name (or directory default-directory))))
         (transform (or transform #'string-trim))
         (environment (append environment process-environment)))
    (derivation-make-input
     (lambda ()
       (let ((default-directory directory)
             (process-environment environment)
             (stderr-file (make-temp-file "derivation-stderr-"))
             (exit nil))
         (unwind-protect
             (with-temp-buffer
               (setq exit (apply #'call-process (car command) nil
                                 (list (current-buffer) stderr-file)
                                 nil (cdr command)))
               (if (zerop exit)
                   (funcall transform (buffer-string))
                 (let ((msg (with-temp-buffer
                              (insert-file-contents stderr-file)
                              (string-trim (buffer-string)))))
                   (signal 'derivation--failed
                           (list (if (string= msg "")
                                     (format "%s exited with status %d"
                                             (car command) exit)
                                   msg))))))
           (delete-file stderr-file))))
     stamp name)))

(defun derivation--make-buffer-deriver (buf tbuf pull-fn push-fn &optional extra-cleanup)
  "Wire a memoized buffer deriver from BUF to TBUF.
PULL-FN computes the target text (may signal `derivation--failed');
PUSH-FN renders it.  Memoized on BUF's `buffer-chars-modified-tick'.
Installs the auto-revert target hooks, registers the deriver with the
kill-buffer hooks (plus EXTRA-CLEANUP), and returns the deriver."
  (let* ((memo (derivation--memoizer pull-fn push-fn
                                     (lambda () (buffer-chars-modified-tick buf))))
         (live (lambda () (and (buffer-live-p buf) (buffer-live-p tbuf))))
         (dirtyp (lambda () (and (funcall live) (funcall (derivation--memo-dirtyp memo)))))
         (guard (lambda (fn)
                  (condition-case nil (funcall fn) (derivation--failed nil))))
         (run (lambda ()
                (when (funcall live)
                  (funcall guard (derivation--memo-force memo)))))
         (deriver (lambda ()
                    (when (funcall live)
                      (funcall guard (derivation--memo-sync memo)))))
         (base (derivation--register-kill-hooks deriver (list buf tbuf)))
         (cleanup (if extra-cleanup
                      (lambda () (funcall base) (funcall extra-cleanup))
                    base)))
    (derivation--install-target-hooks tbuf buf dirtyp run)
    (derivation-register deriver cleanup)
    deriver))

;;;###autoload
(defun derivation-make-deriver (command frombuf tobuf &rest args)
  "Create a memoized function that derives TOBUF from FROMBUF via COMMAND.

FROMBUF and TOBUF may be buffers or buffer names.

COMMAND may be:
  - A string: an external program run via `call-process-region'.
    Extra ARGS are passed as arguments to the command.
  - A function: called with the source buffer contents as its only
    argument.  ARGS are ignored.

The returned function takes no arguments.  When called, it transforms
the contents of FROMBUF through COMMAND and replaces the contents of
TOBUF with the output.  The result is memoized via FROMBUF's
buffer-chars-modified-tick: if FROMBUF hasn't been modified since the
last call, TOBUF is left untouched.

When COMMAND fails (non-zero exit) or the function signals an error,
the target buffer keeps its last good output.  stderr from failed
commands is captured in a hidden buffer.

The target buffer's `buffer-stale-function' and `revert-buffer-function'
are set buffer-locally so `auto-revert-mode' (or Global Auto-Revert with
`global-auto-revert-non-file-buffers') can drive re-derivation."
  (let* ((buf (if (bufferp frombuf) frombuf (get-buffer frombuf)))
         (tbuf (if (bufferp tobuf) tobuf (get-buffer tobuf)))
         ;; Created lazily: only a failing string command needs it.
         (errbuf nil))
    (unless (buffer-live-p tbuf)
      (error "derivation-make-deriver: target buffer is not live"))
    (unless (buffer-live-p buf)
      (error "derivation-make-deriver: source buffer is not live"))
    (derivation--make-buffer-deriver
     buf tbuf
     ;; PULL: run the command.  On failure, record the error and signal
     ;; `derivation--failed' so SYNC aborts without committing the tick
     ;; (the next pass retries).
     (lambda ()
       (let* ((content
               (with-current-buffer buf
                 (buffer-substring-no-properties (point-min) (point-max))))
              (result
               (cl-typecase command
                 (string
                  (let ((stderr-file (make-temp-file "deriv-stderr-"))
                        (exitcode nil))
                    (unwind-protect
                        (with-temp-buffer
                          (setq exitcode
                                (apply #'call-process-region
                                       content nil command nil
                                       (list (current-buffer) stderr-file)
                                       nil args))
                          (let ((stdout (buffer-string)))
                            (if (zerop exitcode)
                                (cons 'ok stdout)
                              (let ((errtext
                                     (with-temp-buffer
                                       (insert-file-contents stderr-file)
                                       (buffer-string))))
                                (cons 'err
                                      (if (string= errtext "")
                                          stdout
                                        errtext))))))
                      (delete-file stderr-file))))
                 (function
                  (condition-case e
                      (cons 'ok (funcall command content))
                    (error (cons 'err (error-message-string e)))))
                 (t
                  (error "COMMAND must be string or function, got %S"
                         (type-of command))))))
         (pcase result
           (`(ok . ,text) text)
           (`(err . ,msg)
            (unless (buffer-live-p errbuf)
              (setq errbuf (generate-new-buffer
                            (format " *derivation-err-%s*" (gensym)))))
            (with-current-buffer errbuf
              (with-silent-modifications
                (erase-buffer)
                (insert msg)))
            (with-current-buffer tbuf
              (setq-local derivation--error msg))
            (signal 'derivation--failed nil)))))
     ;; PUSH: render the text and clear any prior error.
     (lambda (text)
       (with-current-buffer tbuf
         (derivation--replace-contents text)
         (setq-local derivation--error nil))
       (when (buffer-live-p errbuf)
         (with-current-buffer errbuf
           (with-silent-modifications (erase-buffer)))))
     (lambda ()
       (when (buffer-live-p errbuf)
         (kill-buffer errbuf))))))

;;; Generic data derivation

;;;###autoload
(defun derivation-make (pull-fn push-fn &optional stamp-fn)
  "Create a memoized deriver that PULL-FN pulls and PUSH-FN pushes.

PULL-FN is called with no arguments and returns the derived data
\(typically a pure scan of global state).  PUSH-FN is called with
the data and must render it into its target; it is responsible for
selecting the target buffer.

Memoization: the returned deriver pushes only when the data changed
\(compared with `equal'), and copies the data so in-place mutations
are caught on the next run.  When STAMP-FN is given, it is called
before PULL-FN and the pull is skipped entirely while the stamp is
unchanged — use it when PULL-FN is expensive but cheap to version
\(a file mtime, a `buffer-chars-modified-tick', a counter bumped by
a hook).  Without STAMP-FN the deriver polls: every run calls
PULL-FN and pushes only on a data change.

The returned function takes no arguments and is compatible with
`derivation-run-hooks'; it is NOT registered automatically — pass it
to `derivation-register' (or `derivation-unregister') explicitly."
  (let ((memo (derivation--memoizer pull-fn push-fn stamp-fn)))
    (lambda ()
      (funcall (derivation--memo-sync memo)))))

;;;###autoload
(cl-defun derivation-make-tabulated (entries-fn format &key name sort-key)
  "Create a live `tabulated-list-mode' buffer derived from ENTRIES-FN.

ENTRIES-FN is called with no arguments and must return
`tabulated-list-entries': a list of (ID [COLS...]).

FORMAT is the `tabulated-list-format' column spec, e.g.
  [(\"Shell\" 30 t) (\"PID\" 10 my-pid-sorter)].
NAME is the buffer name, SORT-KEY the initial
`tabulated-list-sort-key'.

Each call creates a FRESH buffer (the name is uniquified if taken,
so repeated calls yield \"*shells*\", \"*shells*<2>\", ...) and
registers a deriver that polls ENTRIES-FN on the
`derivation-run-hooks' schedule, re-rendering only when the entries
changed.  The deriver unregisters itself when the buffer is killed.
Errors in ENTRIES-FN leave the last good table and set
`derivation--error', shown as \"⟳!\" by `derivation-mode-line'.
To refresh immediately on an event, wire the event hook to the
runner, e.g. add `buffer-list-update-hook' to a function that calls
`derivation-run-hooks'.

Returns the buffer, populated on creation."
  (unless (functionp entries-fn)
    (error "derivation-make-tabulated: ENTRIES-FN must be a function"))
  (let* ((buf (get-buffer-create
               (generate-new-buffer-name (or name "*derivation*"))))
         (push-fn
          (lambda (entries)
            (with-current-buffer buf
              (setq tabulated-list-entries entries)
              (tabulated-list-print t))))
         (deriver (derivation-make entries-fn push-fn))
         (guarded
          (lambda ()
            (condition-case err
                (prog1 (funcall deriver)
                  (when (buffer-live-p buf)
                    (with-current-buffer buf
                      (setq-local derivation--error nil))))
              (error
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (setq-local derivation--error (error-message-string err))))
               nil))))
         (label (if (symbolp entries-fn)
                    (symbol-name entries-fn)
                  (or name (buffer-name buf)))))
    (with-current-buffer buf
      (tabulated-list-mode)
      (setq-local tabulated-list-format format)
      (when sort-key
        (setq-local tabulated-list-sort-key sort-key))
      (tabulated-list-init-header)
      (setq-local derivation--source
                  (cons label
                        (lambda ()
                          (funcall push-fn (funcall entries-fn))
                          t))))
    (derivation-register guarded
                         (derivation--register-kill-hooks guarded (list buf)))
    (funcall guarded)
    buf))

;;; Variable derivation

(defvar derivation--var-watch-table (make-hash-table :test 'eq)
  "Table mapping source symbols to (GENERATION . REFCOUNT) cons cells.
GENERATION increments on every `setq' or `set' of the symbol via
`add-variable-watcher'.  REFCOUNT tracks how many derivers are
watching this symbol; when it reaches zero, the watcher is removed.")

(defun derivation--var-bump (symbol _newval _op _where)
  "Increment the generation counter for SYMBOL.
Installed as a variable watcher.  _OP is the change operation
\(set, makunbound, let)."
  (cl-incf (car (gethash symbol derivation--var-watch-table))))

;;;###autoload
(defun derivation-make-var-deriver (func fromvar tovar)
  "Create a memoized function that derives TOVAR from FROMVAR via FUNC.

FUNC is called with the value of FROMVAR as its sole argument.
The return value is assigned to TOVAR via `set'.

The returned function takes no arguments and is compatible with
`derivation-run-hooks': it is automatically registered, and can be
removed with `derivation-unregister'.

Memoization is hybrid: a variable watcher provides a fast \"not
dirty\" check, and an `equal' value comparison catches in-place
mutations that the watcher would miss.

Registration installs a watcher on FROMVAR.  `derivation-unregister'
drops the watcher once the last deriver watching FROMVAR is removed."
  (let ((entry (gethash fromvar derivation--var-watch-table))
        (memo (derivation--memoizer
               (lambda () (symbol-value fromvar))
               (lambda (val) (set tovar (funcall func val))))))
    ;; Install or bump refcount.
    (if entry
        (cl-incf (cdr entry))
      (puthash fromvar (cons 0 1) derivation--var-watch-table)
      (add-variable-watcher fromvar #'derivation--var-bump))
    (let ((deriver (lambda () (funcall (derivation--memo-sync memo)))))
      (derivation-register
       deriver
       (lambda ()
         (let ((rec (gethash fromvar derivation--var-watch-table)))
           (when rec
             (if (> (cdr rec) 1)
                 (cl-decf (cdr rec))
               (remhash fromvar derivation--var-watch-table)
               (remove-variable-watcher fromvar #'derivation--var-bump))))))
      deriver)))

;;; Section tree walk

(defun derivation--walk-tree (root predicate &optional skip-root)
  "Traverse the section tree from ROOT, collecting nodes matching PREDICATE.
Children are read from each node's EIEIO `children' slot (the only
concrete tree is magit's `magit-section').  Returns matching nodes in
preorder.  When SKIP-ROOT is non-nil, PREDICATE is not applied to ROOT
itself, only to its descendants."
  (let ((results nil))
    (cl-labels ((children (node)
                  (with-no-warnings (slot-value node 'children)))
                (walk (node)
                  (when (funcall predicate node)
                    (push node results))
                  (dolist (child (children node))
                    (walk child))))
      (if skip-root
          (dolist (child (children root))
            (walk child))
        (walk root)))
    (nreverse results)))

;;; Section filter derivation

;;;###autoload
(defun derivation-make-section-filter (predicate frombuf tobuf)
  "Create a memoized function that copies matching sections to TOBUF.

FROMBUF is a buffer using magit-section (e.g., a magit buffer).
PREDICATE is called with each child section of FROMBUF's root
(with FROMBUF current).  Sections for which PREDICATE returns
non-nil have their buffer text (including text properties)
copied to TOBUF, separated by newlines.

The returned function takes no arguments and is compatible with
`derivation-run-hooks': it is automatically registered, and can be
removed with `derivation-unregister'.  The deriver is unregistered
automatically when FROMBUF or TOBUF is killed.

Memoization is keyed on FROMBUF's buffer-chars-modified-tick.

Example that filters magit-process to show only failed commands:

  (derivation-register (derivation-make-section-filter
         (lambda (section)
           (let ((proc (slot-value section \\='value)))
             (and (processp proc)
                  (numberp (process-exit-status proc))
                  (/= 0 (process-exit-status proc)))))
         (magit-process-buffer t)
         (get-buffer-create \"*magit-failures*\")))"
  (let ((buf (if (bufferp frombuf) frombuf (get-buffer frombuf)))
        (tbuf (if (bufferp tobuf) tobuf (get-buffer tobuf))))
    (unless (buffer-live-p tbuf)
      (error "derivation-make-section-filter: target buffer is not live"))
    (unless (buffer-live-p buf)
      (error "derivation-make-section-filter: source buffer is not live"))
    (derivation--make-buffer-deriver
     buf tbuf
     (lambda ()
       (with-current-buffer buf
         (if (and (boundp 'magit-root-section)
                  (local-variable-p 'magit-root-section)
                  magit-root-section)
             (mapconcat
              (lambda (section)
                (with-no-warnings
                  (buffer-substring (slot-value section 'start)
                                    (slot-value section 'end))))
              (derivation--walk-tree magit-root-section predicate t)
              "\n")
           (buffer-string))))
     (lambda (text)
       (with-current-buffer tbuf
         (derivation--replace-contents text))))))

(defvar-local derivation--source nil
  "When non-nil, this buffer is a derivation target.
Value is (SOURCE . RUN-FN).  SOURCE is a buffer or a string label
\(data derivations have no source buffer); it is shown by
`derivation-mode-line' and used by `derivation-jump-to-source'.
RUN-FN recomputes the target bypassing memoization; used by
`derivation-rerun' and `revert-buffer'.")

(defun derivation--install-target-hooks (tbuf source dirtyp run)
  "Mark TBUF as a derivation target and wire up auto-revert support.
SOURCE is recorded in `derivation--source'.  DIRTYP is a zero-arg
predicate returning non-nil when TBUF is out of date.  RUN is a
zero-arg function that recomputes TBUF and marks it up to date; it is
what `derivation-rerun' and `revert-buffer' invoke.

This sets TBUF's buffer-local `buffer-stale-function' and
`revert-buffer-function' so `auto-revert-mode' (or
`global-auto-revert-mode' together with
`global-auto-revert-non-file-buffers') can drive the derivation."
  (with-current-buffer tbuf
    ;; The cdr bypasses memoization (used by `derivation-rerun').
    (setq-local derivation--source (cons source run))
    (setq-local buffer-stale-function
                (lambda (&optional _noconfirm) (funcall dirtyp)))
    (setq-local revert-buffer-function
                (lambda (&rest _) (funcall run) t))))

(defun derivation--source-label (source)
  "Return a display name for SOURCE, a buffer or a string label."
  (if (bufferp source) (buffer-name source) source))

(defvar-local derivation--error nil
  "When non-nil, the last derivation produced an error.
Value is the error message string.  Used by `derivation-mode-line'
to show an error indicator.")

(defvar derivation--mode-line-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'derivation-jump-to-source)
    map)
  "Keymap for the `derivation-mode-line' indicator.
Clicking the indicator jumps to the source buffer.")

(defvar derivation-mode-line
  '(:eval (when derivation--source
            (if derivation--error
                (propertize " ⟳!"
                            'face 'error
                            'help-echo (format "derived from %s (error: %s)"
                                               (derivation--source-label
                                                (car derivation--source))
                                               derivation--error)
                            'mouse-face 'mode-line-highlight
                            'local-map derivation--mode-line-map)
              (propertize " ⟳"
                          'help-echo (format "derived from %s"
                                             (derivation--source-label
                                              (car derivation--source)))
                          'mouse-face 'mode-line-highlight
                          'local-map derivation--mode-line-map))))
  "Mode-line construct showing derivation status.
Add to `mode-line-format' to see which buffers are derived.
Shows \"⟳\" normally, \"⟳!\" in error face when the last run failed.
Click to jump to the source buffer.")

(defun derivation-rerun ()
  "Re-run the derivation chain that produced the current buffer.
Walks `derivation--source' transitively: if this target is itself the
source of another derivation, that one is re-run too, so a pipeline
converges in a single call.  Re-runs bypass memoization."
  (interactive)
  (unless derivation--source
    (user-error "Buffer is not a derivation target"))
  (let ((chain nil)
        (buf (current-buffer)))
    ;; Collect the chain of buffers, current → upstream.  PUSHing while
    ;; walking upstream leaves CHAIN in upstream → downstream order.
    (while (and buf (buffer-live-p buf)
                (not (member buf chain)))
      (push buf chain)
      (setq buf (car (buffer-local-value 'derivation--source buf))))
    ;; CHAIN is already upstream → downstream: run it as-is, so each
    ;; transform reads a fresh intermediate.
    (dolist (b chain)
      (let ((rec (buffer-local-value 'derivation--source b)))
        (when rec
          (funcall (cdr rec)))))))

(defun derivation-jump-to-source ()
  "Switch to the source buffer of this derivation target.
For data derivations whose source is a string label, report it."
  (interactive)
  (if derivation--source
      (let ((src (car derivation--source)))
        (if (bufferp src)
            (switch-to-buffer src)
          (message "Source of this derivation is `%s', not a buffer" src)))
    (user-error "Buffer is not a derivation target")))

(defvar derivation--max-passes 10
  "Maximum fixpoint iterations per `derivation-run-hooks' call.")

;;;###autoload
(defun derivation-run-hooks ()
  "Run all derivers in `derivation--storage' to a fixpoint.
Intended to be called from an idle timer or manually.  Repeatedly
runs the derivers until a pass produces no change, so pipelines
(A→B→C) converge in a single call, not N idle cycles.  Capped at
`derivation--max-passes' iterations per call.

Errors in individual derivers are caught and reported without
aborting the remaining derivers."
  (interactive)
  (let ((passes 0))
    (while (and (< passes derivation--max-passes)
                (derivation--run-one-pass))
      (setq passes (1+ passes)))))

(defun derivation--run-one-pass ()
  "Run all derivers once.  Return non-nil if any deriver changed state."
  (let ((changed nil)
        (records (copy-sequence derivation--storage)))
    (dolist (rec records)
      (condition-case err
          (when (funcall (car rec))
            (setq changed t))
        (error
         (message "derivation: error in deriver: %s"
                  (error-message-string err)))))
    changed))

(provide 'derivation)
;;; derivation.el ends here
