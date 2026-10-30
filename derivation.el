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
;;   (derivation-input-wait my-docs)         ; => "/nix/store/...-cargo-doc"
;;   (derivation-input-invalidate my-docs)   ; force a rebuild next read
;;
;;   ;; A long-running server, restarted when the docs path changes.
;;   (defvar my-docs-server
;;     (derivation-make-process
;;      :name "docs-http"
;;      :command (list "darkhttpd" my-docs "--port" "8081")
;;      :directory my-docs))
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
;; External commands in `derivation-make-deriver' and
;; `derivation-make-command-input' run asynchronously: a call starts the
;; command and returns, and the target value arrives on a later
;; `derivation-run-hooks' pass.  Use `derivation-input-wait' to block
;; for a command input when you need the value immediately.
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

(cl-defstruct (derivation-process (:constructor derivation--process-create)
                                   (:copier nil))
  "A long-running child process reconciled against a live spec.
COMMAND, DIRECTORY and ENVIRONMENT hold unresolved spec forms
(strings, `derivation-input's or functions).  SPEC holds the
resolved runtime spec of the current or last process;
PENDING-SPEC holds a debounced change.  DERIVER is the function
registered with `derivation-run-hooks'.  AUTO-RESTART, BACKOFF, STOP-SIGNAL, STOP-TIMEOUT, DEBOUNCE and
ON-CHANGE are policy options.  STATUS is one of `:starting',
`:running', `:stopping', `:exited', `:stopped' or `:failed'."
  name command directory environment
  spec pending-spec next-spec inputs
  log deriver process
  desired status
  auto-restart backoff stop-signal stop-timeout debounce on-change
  timer restart-timer stop-timer restart-count started-at stoppingp
  last-error kill-hook)

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
DERIVER is a deriver function or a `derivation-process' handle.
Deriver records are also removed automatically when their source or
target buffer is killed; this is for manual teardown.

Returns non-nil if DERIVER was registered."
  (when (derivation-process-p deriver)
    (setq deriver (derivation-process-deriver deriver)))
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

;; Signal raised by an asynchronous PULL-FN while its command runs.  The
;; stamp stays uncommitted, so the next pass retries.
(define-error 'derivation--pending "Derivation pending")

(defvar derivation--resolving-inputs nil
  "Inputs seen by the current spec resolution.
Bound by `derivation--resolve-spec'.")

(defvar derivation--retry-delay 1.0
  "Seconds to wait before retrying a failed asynchronous command.")

;;; Asynchronous external commands

(cl-defstruct (derivation--command (:constructor derivation--command-create)
                                   (:copier nil))
  "An asynchronous external command.
PROCESS is the child.  PROGRAM is the user's program name, kept for
error messages.  STDOUT and STDERR are temp buffers.  STDIN-FILE,
when non-nil, holds the input content written to disk (a seekable
stdin).  TICK is the caller's stamp at start.  DONE is non-nil after
the sentinel runs.  OUTPUT holds stdout text on success, ERROR holds
stderr text on failure."
  process stdout stderr stdin-file tick done output error program)

(defun derivation--command-sentinel (command proc _event)
  "Record PROC's completion in COMMAND."
  (when (and (eq proc (derivation--command-process command))
             (buffer-live-p (derivation--command-stdout command))
             (buffer-live-p (derivation--command-stderr command)))
    (setf (derivation--command-done command) t)
    (let ((status (ignore-errors (process-exit-status proc))))
      (if (equal status 0)
          (with-current-buffer (derivation--command-stdout command)
            (setf (derivation--command-output command) (buffer-string)))
        (let ((text (with-current-buffer (derivation--command-stderr command)
                      (string-trim (buffer-string)))))
          (setf (derivation--command-error command)
                (if (string= text "")
                    (format "%s exited with status %s"
                            (or (derivation--command-program command) "command")
                            status)
                  text)))))))

(defun derivation--command-start (command args content tick)
  "Start COMMAND with ARGS.  CONTENT feeds stdin, or nil for /dev/null.

CONTENT goes to a temp file, so stdin stays seekable (some filters
read it twice).  TICK is recorded for the caller's staleness checks.
A failure to start the program becomes a completed command with an
ERROR, so the usual pull path reports it."
  (let* ((stdin-file (and content (make-temp-file "derivation-stdin-")))
         (stdout (generate-new-buffer " *derivation-stdout*"))
         (stderr (generate-new-buffer " *derivation-stderr*"))
         (object (derivation--command-create
                  :program command
                  :stdout stdout :stderr stderr
                  :stdin-file stdin-file :tick tick)))
    (condition-case err
        (progn
          (when stdin-file
            (let ((coding-system-for-write 'utf-8-unix))
              (with-temp-file stdin-file
                (insert content))))
          (let* ((script (if stdin-file
                             "file=$1; shift; exec \"$@\" < \"$file\""
                           "exec \"$@\" < /dev/null"))
                 (full (if stdin-file
                           (append (list "sh" "-c" script "sh" stdin-file command)
                                   args)
                         (append (list "sh" "-c" script "sh" command)
                                 args)))
                 (proc (make-process
                        :name "derivation-command"
                        :command full
                        :buffer stdout
                        :stderr stderr
                        :coding 'utf-8-unix
                        :connection-type 'pipe
                        :noquery t
                        :sentinel
                        (lambda (p event)
                          (derivation--command-sentinel object p event)))))
            (setf (derivation--command-process object) proc)
            (set-process-coding-system proc 'utf-8-unix 'utf-8-unix)))
      (error
       (setf (derivation--command-done object) t
             (derivation--command-error object) (error-message-string err))))
    object))

(defun derivation--command-cleanup (command)
  "Kill COMMAND's stdout and stderr buffers and stdin temp file."
  (dolist (buf (list (derivation--command-stdout command)
                     (derivation--command-stderr command)))
    (when (buffer-live-p buf)
      (kill-buffer buf)))
  (let ((file (derivation--command-stdin-file command)))
    (when (and file (file-exists-p file))
      (ignore-errors (delete-file file)))))

(defun derivation--command-kill (command)
  "Kill COMMAND's child and buffers."
  (let ((proc (derivation--command-process command)))
    (when (and proc (process-live-p proc))
      (ignore-errors (delete-process proc))))
  (derivation--command-cleanup command))

(defun derivation--command-consume (command)
  "Return COMMAND's output, or signal `derivation--failed'.
Kill COMMAND's buffers in either case."
  (unwind-protect
      (if (derivation--command-error command)
          (signal 'derivation--failed
                  (list (derivation--command-error command)))
        (derivation--command-output command))
    (derivation--command-cleanup command)))

(cl-defstruct (derivation--memo (:constructor derivation--memo-create))
  "Memoization state for a PULL-FN/PUSH-FN pipeline.
DIRTYP, SYNC, FORCE and VALUE are closures; see `derivation--memoizer'."
  dirtyp sync force value)

(defun derivation--memoizer (pull-fn push-fn &optional stamp-fn)
  "Build memoization state for PULL-FN/PUSH-FN versioned by STAMP-FN.

Return a `derivation--memo' with four closures:

  DIRTYP  non-nil when the stamp changed since the last commit (always
          non-nil when STAMP-FN is nil: polling mode).
  SYNC    pull, commit the stamp, push when the data changed.  Returns
          non-nil when it pushed.
  FORCE   pull and push unconditionally, committing the stamp and the
          data (bypasses memoization; used by rerun/revert).

  VALUE   return the last pulled data, running SYNC first when the
          memo is dirty.  Used by `derivation-input'.

PULL-FN may signal `derivation--failed' to abort without committing the
stamp, so a later SYNC retries.  It may also signal
`derivation--pending' while asynchronous work runs; that also leaves
the stamp uncommitted, but callers treat it as \"try again later\"
rather than an error.  The signal propagates to the caller."
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

(defun derivation--make-input (pull push &optional stamp name poll)
  "Build a `derivation-input' around PULL and PUSH.

PUSH renders the pulled value and runs only when the value changed.
Public value inputs pass `ignore'.  STAMP and NAME go to the input.
POLL non-nil gives the memo no stamp, so every sync pulls (used by
variable derivers to catch in-place mutations)."
  (let ((input (derivation--input-create
                :name name :pull pull :stamp stamp :generation 0)))
    (setf (derivation-input-memo input)
          (derivation--memoizer
           pull push
           ;; The generation counter makes every input manually
           ;; invalidatable even when it carries a stamp.
           (unless poll
             (lambda ()
               (list (derivation-input-generation input)
                     (and stamp (funcall stamp)))))))
    input))

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
the message in `derivation-input-error'.  A PULL may also signal
`derivation--pending' while asynchronous work runs; use
`derivation-input-wait' to block for the value, and let derivations
propagate the signal.

See `derivation-stamp-or', `derivation-stamp-mtime',
`derivation-stamp-files', `derivation-stamp-git' and
`derivation-stamp-always' for stamp constructors."
  (unless (functionp pull)
    (error "derivation-make-input: PULL must be a function, got %S"
           (type-of pull)))
  (when (and stamp (not (functionp stamp)))
    (error "derivation-make-input: STAMP must be a function or nil, got %S"
           (type-of stamp)))
  (derivation--make-input pull #'ignore stamp name))

;;;###autoload
(defun derivation-make-buffer-input (buffer &optional name)
  "Return a live input for BUFFER's accessible text.

The input's stamp is BUFFER's `buffer-chars-modified-tick', so the
value updates after edits.  NAME defaults to the buffer name."
  (let ((buffer (if (bufferp buffer) buffer (get-buffer buffer))))
    (unless (buffer-live-p buffer)
      (error "derivation-make-buffer-input: buffer is not live"))
    (derivation--make-input
     (lambda ()
       (with-current-buffer buffer
         (buffer-substring-no-properties (point-min) (point-max))))
     #'ignore
     (lambda () (buffer-chars-modified-tick buffer))
     (or name (buffer-name buffer)))))

(defun derivation-input-value (input)
  "Return the current value of INPUT, pulling again when stale.

When PULL fails, the last good value stays cached, the message lands
in `derivation-input-error', and the `derivation--failed' signal
propagates.  While asynchronous work runs, this signals
`derivation--pending'; use `derivation-input-wait' to block for the
value."
  (unless (derivation-input-p input)
    (error "derivation-input-value: not a derivation-input: %S" input))
  (condition-case err
      (prog1 (funcall (derivation--memo-value (derivation-input-memo input)))
        (setf (derivation-input-error input) nil))
    (derivation--pending
     (signal 'derivation--pending nil))
    (derivation--failed
     (setf (derivation-input-error input)
           (or (cadr err) (error-message-string err)))
     (signal (car err) (cdr err)))))

(defun derivation-input-wait (input &optional timeout)
  "Return INPUT's value, waiting for asynchronous work to finish.

Blocks up to TIMEOUT seconds (default 30) by pumping process output.
Use this only when you need the value now; derivations and process
specs should let `derivation--pending' propagate instead."
  (unless (derivation-input-p input)
    (error "derivation-input-wait: not a derivation-input: %S" input))
  (let ((deadline (time-add (current-time) (or timeout 30)))
        (value nil)
        (done nil))
    (while (and (not done) (time-less-p (current-time) deadline))
      (condition-case nil
          (setq value (derivation-input-value input)
                done t)
        (derivation--pending
         (accept-process-output nil 0.05))))
    (unless done
      (error "derivation-input-wait: timed out waiting for %S"
             (or (derivation-input-name input) input)))
    value))

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
(defun derivation--command-environment (forms)
  "Resolve command-input environment FORMS.

Entries are \"VAR=VALUE\" strings or (VAR . VALUE) conses with string
values.  A nil VALUE becomes (VAR), which unsets the variable."
  (let ((entries nil))
    (dolist (entry forms)
      (cond
       ((stringp entry)
        (push entry entries))
       ((and (consp entry) (stringp (cdr entry)))
        (push (concat (format "%s" (car entry)) "=" (cdr entry)) entries))
       ((and (consp entry) (null (cdr entry)))
        (push (list (format "%s" (car entry))) entries))
       (t
        (error "Command input environment values must be strings: %S" entry))))
    (nreverse entries)))

(cl-defun derivation-make-command-input (command &key directory environment
                                                 stamp transform name)
  "Create a live value from the stdout of a one-shot COMMAND.

COMMAND is a list (PROGRAM ARG...).  It runs asynchronously via
`make-process'.  `derivation-input-value' signals
`derivation--pending' until the command finishes; use
`derivation-input-wait' for a blocking read.  DIRECTORY is the
working directory (default: the `default-directory' at creation).
ENVIRONMENT is a list of \"VAR=VALUE\" strings or (VAR . VALUE)
conses with string values, prepended to `process-environment' so it
overrides inherited variables.  TRANSFORM post-processes stdout
\(default `string-trim', which drops the trailing newline that most
commands print).  STAMP, NAME and error handling are as in
`derivation-make-input'.

On a non-zero exit the input signals `derivation--failed' with the
captured stderr (or an exit-status message when stderr is empty).  A
command started for an older stamp is discarded when STAMP changed
meanwhile.

Use this for expensive value producers such as
\='(\"nix\" \"build\" \"--no-out-link\" \".#docs\").  Pair it with a cheap
STAMP so the command runs only when its inputs change."
  (unless (and (listp command) (stringp (car command)))
    (error "derivation-make-command-input: COMMAND must be (PROGRAM ARG...)"))
  (dolist (arg command)
    (unless (stringp arg)
      (error "derivation-make-command-input: COMMAND elements must be strings: %S"
             arg)))
  (when (and stamp (not (functionp stamp)))
    (error "derivation-make-command-input: STAMP must be a function or nil"))
  (when (and transform (not (functionp transform)))
    (error "derivation-make-command-input: TRANSFORM must be a function or nil"))
  (let* ((directory (file-name-as-directory
                     (expand-file-name (or directory default-directory))))
         (transform (or transform #'string-trim))
         (input (derivation--input-create
                 :name name :stamp stamp :generation 0))
         (job nil)
         (retry-at nil)
         (retry-stamp nil)
         (kill-job
          (lambda ()
            (when job
              (derivation--command-kill job)
              (setq job nil))))
         (effective-stamp
          (lambda ()
            (list (derivation-input-generation input)
                  (and stamp (funcall stamp)))))
         (start-job
          (lambda (current)
            (let ((default-directory directory)
                  (process-environment
                   (derivation--process-environment
                    (derivation--command-environment environment))))
              (setq job (derivation--command-start
                         (car command) (cdr command) nil current)))))
         (start-new
          (lambda (current)
            (if (and retry-at
                     (time-less-p (current-time) retry-at)
                     (equal retry-stamp current))
                (signal 'derivation--pending nil)
              (setq retry-at nil retry-stamp nil)
              (funcall start-job current)
              (signal 'derivation--pending nil))))
         (pull
          (lambda ()
            (let ((current (funcall effective-stamp)))
              (cond
               ((and job (derivation--command-done job))
                (if (equal (derivation--command-tick job) current)
                    (let ((done job))
                      (setq job nil)
                      (condition-case err
                          (funcall transform (derivation--command-consume done))
                        (derivation--failed
                         (setq retry-at (time-add
                                         (current-time)
                                         derivation--retry-delay)
                               retry-stamp current)
                         (signal 'derivation--failed (cdr err)))))
                  (funcall kill-job)
                  (funcall start-new current)))
               ((and job (equal (derivation--command-tick job) current))
                (signal 'derivation--pending nil))
               (t
                (funcall kill-job)
                (funcall start-new current)))))))
    (setf (derivation-input-pull input) pull
          (derivation-input-memo input)
          (derivation--memoizer pull #'ignore effective-stamp))
    input))

(defun derivation--make-buffer-deriver (buf tbuf input
                                          &optional reset-fn pendingp extra-cleanup)
  "Wire a memoized buffer deriver from BUF to TBUF via INPUT.

INPUT is a `derivation-input' whose PUSH-FN renders TBUF; its PULL-FN
may signal `derivation--failed' or `derivation--pending'.  Memoized on
the input's stamp (usually BUF's `buffer-chars-modified-tick').
RESET-FN, when non-nil, aborts any work in flight before a forced
rerun.  PENDINGP, when non-nil, reports that work for the current
stamp already runs, so staleness checks stay quiet.  Installs the
auto-revert target hooks, registers the deriver with the kill-buffer
hooks (plus EXTRA-CLEANUP), and returns the deriver."
  (let* ((memo (derivation-input-memo input))
         (live (lambda () (and (buffer-live-p buf) (buffer-live-p tbuf))))
         (dirtyp (lambda ()
                   (and (funcall live)
                        (not (and pendingp (funcall pendingp)))
                        (funcall (derivation--memo-dirtyp memo)))))
         (guard (lambda (fn)
                  (condition-case nil (funcall fn)
                    (derivation--failed nil)
                    (derivation--pending nil))))
         (run (lambda ()
                (when (funcall live)
                  (when reset-fn (funcall reset-fn))
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
  - A string: an external program.  The command runs asynchronously:
    a call starts it and returns; the target updates on a later
    `derivation-run-hooks' pass, when the command finished.  Extra
    ARGS are passed as arguments to the command.
  - A function: called synchronously with the source buffer contents
    as its only argument.  ARGS are ignored.

The returned function takes no arguments.  When called, it transforms
the contents of FROMBUF through COMMAND and replaces the contents of
TOBUF with the output.  The result is memoized via FROMBUF's
buffer-chars-modified-tick: if FROMBUF hasn't been modified since the
last call, TOBUF is left untouched.  A command started for an older
tick is discarded when the source changed meanwhile.

When COMMAND fails (non-zero exit) or the function signals an error,
the target buffer keeps its last good output.  stderr from failed
commands is captured in a hidden buffer.  A failed command is retried
on the next pass.

The target buffer's `buffer-stale-function' and `revert-buffer-function'
are set buffer-locally so `auto-revert-mode' (or Global Auto-Revert with
`global-auto-revert-non-file-buffers') can drive re-derivation.
`revert-buffer' and `derivation-rerun' start a fresh command and return
before it finishes."
  (unless (or (stringp command) (functionp command))
    (error "derivation-make-deriver: COMMAND must be a string or function, got %S"
           (type-of command)))
  (let ((buf (if (bufferp frombuf) frombuf (get-buffer frombuf)))
        (tbuf (if (bufferp tobuf) tobuf (get-buffer tobuf))))
    (unless (buffer-live-p tbuf)
      (error "derivation-make-deriver: target buffer is not live"))
    (unless (buffer-live-p buf)
      (error "derivation-make-deriver: source buffer is not live"))
    (if (stringp command)
        (let* ((job nil)
               (retry-at nil)
               (retry-tick nil)
               (kill-job
                (lambda ()
                  (when job
                    (derivation--command-kill job)
                    (setq job nil))))
               (reset
                (lambda ()
                  (funcall kill-job)
                  (setq retry-at nil retry-tick nil)))
               (start-job
                (lambda ()
                  (let ((tick (buffer-chars-modified-tick buf))
                        (content (with-current-buffer buf
                                   (buffer-substring-no-properties
                                    (point-min) (point-max)))))
                    (setq job (derivation--command-start
                               command args content tick)))))
               (start-new
                (lambda ()
                  (let ((tick (buffer-chars-modified-tick buf)))
                    (if (and retry-at
                             (time-less-p (current-time) retry-at)
                             (equal retry-tick tick))
                        (signal 'derivation--pending nil)
                      (setq retry-at nil retry-tick nil)
                      (funcall start-job)
                      (signal 'derivation--pending nil)))))
               (pull
                (lambda ()
                  (cond
                   ((and job (derivation--command-done job))
                    (if (equal (derivation--command-tick job)
                               (buffer-chars-modified-tick buf))
                        (let ((done job))
                          (setq job nil)
                          (condition-case err
                              (derivation--command-consume done)
                            (derivation--failed
                             (setq retry-at (time-add
                                             (current-time)
                                             derivation--retry-delay)
                                   retry-tick (derivation--command-tick done))
                             (let ((msg (or (cadr err)
                                            (error-message-string err))))
                               (with-current-buffer tbuf
                                 (setq-local derivation--error msg)))
                             (signal 'derivation--failed (cdr err)))))
                      (funcall kill-job)
                      (funcall start-new)))
                   ((and job
                         (equal (derivation--command-tick job)
                                (buffer-chars-modified-tick buf)))
                    (signal 'derivation--pending nil))
                   (t
                    (funcall kill-job)
                    (funcall start-new)))))
               (push-fn
                (lambda (text)
                  (with-current-buffer tbuf
                    (derivation--replace-contents text)
                    (setq-local derivation--error nil)))))
          (derivation--make-buffer-deriver
           buf tbuf
           (derivation--make-input
            pull push-fn
            (lambda () (buffer-chars-modified-tick buf))
            (buffer-name buf))
           reset
           (lambda ()
             (let ((tick (buffer-chars-modified-tick buf)))
               (or (and job
                        (equal (derivation--command-tick job) tick))
                   (and retry-at
                        (time-less-p (current-time) retry-at)
                        (equal retry-tick tick)))))
           kill-job))
      ;; Function transform: synchronous.
      (let ((errbuf nil))
        (derivation--make-buffer-deriver
         buf tbuf
         (derivation--make-input
          (lambda ()
            (let ((content (with-current-buffer buf
                             (buffer-substring-no-properties
                              (point-min) (point-max)))))
              (condition-case err
                  (funcall command content)
                (error
                 (let ((msg (error-message-string err)))
                   (unless (buffer-live-p errbuf)
                     (setq errbuf (generate-new-buffer
                                   (format " *derivation-err-%s*" (gensym)))))
                   (with-current-buffer errbuf
                     (with-silent-modifications
                       (erase-buffer)
                       (insert msg)))
                   (with-current-buffer tbuf
                     (setq-local derivation--error msg))
                   (signal 'derivation--failed nil))))))
          (lambda (text)
            (with-current-buffer tbuf
              (derivation--replace-contents text)
              (setq-local derivation--error nil))
            (when (buffer-live-p errbuf)
              (with-current-buffer errbuf
                (with-silent-modifications (erase-buffer)))))
          (lambda () (buffer-chars-modified-tick buf))
          (buffer-name buf))
         nil
         nil
         (lambda ()
           (when (buffer-live-p errbuf)
             (kill-buffer errbuf))))))))

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
              (derivation--pending nil)
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

Memoization: the deriver polls the source value on every pass and
pushes only when the value changed (`equal' on a copied tree), so
in-place mutations are caught.  The variable watcher exists for
refcounted registration, not for skipping the pull.

Registration installs a watcher on FROMVAR.  `derivation-unregister'
drops the watcher once the last deriver watching FROMVAR is removed."
  (let ((entry (gethash fromvar derivation--var-watch-table))
        (input (derivation--make-input
                (lambda () (symbol-value fromvar))
                (lambda (val) (set tovar (funcall func val)))
                nil
                (symbol-name fromvar)
                t)))
    ;; Install or bump refcount.
    (if entry
        (cl-incf (cdr entry))
      (puthash fromvar (cons 0 1) derivation--var-watch-table)
      (add-variable-watcher fromvar #'derivation--var-bump))
    (let ((deriver (lambda ()
                     (funcall (derivation--memo-sync
                               (derivation-input-memo input))))))
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
     (derivation--make-input
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
          (derivation--replace-contents text)))
      (lambda () (buffer-chars-modified-tick buf))
      (buffer-name buf)))))

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

;;; Process derivation

(defun derivation-process-live-p (process)
  "Return non-nil when PROCESS has a live child."
  (let ((proc (derivation-process-process process)))
    (and proc (process-live-p proc))))

(defun derivation-process-exit-status (process)
  "Return the exit status of PROCESS's last child, or nil."
  (let ((proc (derivation-process-process process)))
    (when proc (process-exit-status proc))))

(defun derivation--process-set-error (process message)
  "Record MESSAGE as PROCESS's error, buffer-locally in its log."
  (setf (derivation-process-last-error process) message)
  (let ((log (derivation-process-log process)))
    (when (buffer-live-p log)
      (with-current-buffer log
        (setq-local derivation--error message)))))

(defun derivation--process-clear-error (process)
  "Clear PROCESS's error state."
  (setf (derivation-process-last-error process) nil)
  (let ((log (derivation-process-log process)))
    (when (buffer-live-p log)
      (with-current-buffer log
        (setq-local derivation--error nil)))))

(defun derivation--process-cancel-timer (process)
  "Cancel PROCESS's debounce timer and any pending spec."
  (let ((timer (derivation-process-timer process)))
    (when timer
      (cancel-timer timer)))
  (setf (derivation-process-timer process) nil
        (derivation-process-pending-spec process) nil))

(defun derivation--process-cancel-restart-timer (process)
  "Cancel PROCESS's crash-backoff timer."
  (let ((timer (derivation-process-restart-timer process)))
    (when timer
      (cancel-timer timer)))
  (setf (derivation-process-restart-timer process) nil))

(defun derivation--process-cancel-stop-timer (process)
  "Cancel PROCESS's pending SIGKILL timer."
  (let ((timer (derivation-process-stop-timer process)))
    (when timer
      (cancel-timer timer)))
  (setf (derivation-process-stop-timer process) nil))

(defun derivation--process-backoff-cap (process)
  "Return the longest backoff delay of PROCESS, in seconds."
  (float (or (car (last (derivation-process-backoff process))) 5)))

(defun derivation--process-reset-backoff-if-stable (process)
  "Reset PROCESS's backoff after a run longer than its cap."
  (let ((started (derivation-process-started-at process)))
    (when (and started
               (>= (float-time (time-since started))
                   (derivation--process-backoff-cap process)))
      (setf (derivation-process-restart-count process) 0))))

(defun derivation--process-schedule-restart (process)
  "Schedule PROCESS's next crash restart with backoff."
  (unless (derivation-process-restart-timer process)
    (let* ((backoff (or (derivation-process-backoff process)
                        '(0.5 1 2 5)))
           (index (min (derivation-process-restart-count process)
                       (1- (length backoff))))
           (delay (nth index backoff)))
      (cl-incf (derivation-process-restart-count process))
      (setf (derivation-process-restart-timer process)
            (run-at-time delay nil
                         (lambda ()
                           (setf (derivation-process-restart-timer process) nil)
                           (when (and (derivation-process-desired process)
                                      (not (derivation-process-stoppingp process)))
                             (derivation--process-apply process))))))))

(defun derivation--resolve-value (form)
  "Resolve FORM to a value, recording the inputs it reads."
  (cond
   ((derivation-input-p form)
    (push form derivation--resolving-inputs)
    (derivation-input-value form))
   ((functionp form)
    (derivation--resolve-value (funcall form)))
   (t form)))

(defun derivation--resolve-command (forms)
  "Resolve FORMS into a command list of strings."
  (unless (and (listp forms) forms)
    (error "Process command must be a non-empty list, got %S" forms))
  (let ((command (mapcar #'derivation--resolve-value forms)))
    (dolist (arg command)
      (unless (stringp arg)
        (error "Process command element did not resolve to a string: %S" arg)))
    command))

(defun derivation--program-stamp (program directory)
  "Return PROGRAM's identity, resolving relative paths against DIRECTORY.

The identity is (TRUENAME INODE SIZE MTIME), or nil when PROGRAM
resolves to no file.  Replacing or retargeting the executable changes
the stamp, so a running child restarts even when its argv stays the
same."
  (let* ((path (if (file-name-directory program)
                   (expand-file-name program directory)
                 (executable-find program))))
    (when path
      (let ((attrs (file-attributes path)))
        (when attrs
          (list (file-truename path)
                (file-attribute-inode-number attrs)
                (file-attribute-size attrs)
                (file-attribute-modification-time attrs)))))))

(defun derivation--resolve-directory (process)
  "Resolve PROCESS's working directory."
  (let ((directory (derivation--resolve-value
                    (derivation-process-directory process))))
    (unless (stringp directory)
      (error "Process directory did not resolve to a string: %S" directory))
    (file-name-as-directory (expand-file-name directory))))

(defun derivation--resolve-environment (forms)
  "Resolve FORMS into environment entries.

FORMS is a list of \"VAR=VALUE\" strings or (VAR . VALUE) conses.
Each entry resolves to a \"VAR=VALUE\" string, or to (VAR) when VALUE
is nil: the variable is then removed from the inherited environment."
  (let ((entries nil))
    (dolist (entry forms)
      (cond
       ((stringp entry)
        (push entry entries))
       ((consp entry)
        (let ((var (format "%s" (car entry)))
              (value (derivation--resolve-value (cdr entry))))
          (push (if value
                    (concat var "=" (format "%s" value))
                  (list var))
                entries)))
       (t
        (error "Bad process environment entry: %S" entry))))
    (nreverse entries)))

(defun derivation--process-environment (entries)
  "Build `process-environment' from resolved ENTRIES.

ENTRIES shadows inherited variables of the same name.  An (VAR) entry
removes VAR from the inherited environment."
  (let ((inherited process-environment)
        (additions nil)
        (names nil))
    (dolist (entry entries)
      (if (stringp entry)
          (progn
            (push entry additions)
            (push (substring entry 0 (or (string-match "=" entry)
                                         (length entry)))
                  names))
        (push (car entry) names)))
    (dolist (name names)
      (setq inherited
            (cl-remove-if (lambda (entry)
                            (string-prefix-p (concat name "=") entry))
                          inherited)))
    (append (nreverse additions) inherited)))

(defun derivation--resolve-spec (process)
  "Resolve PROCESS's spec.  Return (SPEC . INPUTS)."
  (let* ((derivation--resolving-inputs nil)
         (directory (derivation--resolve-directory process))
         (command (derivation--resolve-command
                   (derivation-process-command process)))
         (spec (list :command command
                     :program (derivation--program-stamp (car command)
                                                         directory)
                     :directory directory
                     :environment
                     (derivation--resolve-environment
                      (derivation-process-environment process))))
         (inputs (cl-delete-duplicates
                  (nreverse derivation--resolving-inputs) :test #'eq)))
    (cons spec inputs)))

(defun derivation--process-start (process spec)
  "Start PROCESS's child from SPEC.  Return non-nil on success."
  (let ((command (plist-get spec :command))
        (directory (plist-get spec :directory))
        (environment (plist-get spec :environment))
        (log (derivation-process-log process)))
    (derivation--process-cancel-restart-timer process)
    (derivation--process-cancel-stop-timer process)
    (condition-case err
        (progn
          (when (buffer-live-p log)
            (with-current-buffer log
              (goto-char (point-max))
              (insert (format "\n;; %s starting %S\n"
                              (format-time-string "%F %T") command))))
          (let ((default-directory directory)
                (process-environment
                 (derivation--process-environment environment)))
            (setf (derivation-process-process process)
                  (make-process
                   :name (derivation-process-name process)
                   :command command
                   :buffer log
                   :stderr log
                   :coding 'utf-8-unix
                   :connection-type 'pipe
                   :noquery t
                   :sentinel
                   (lambda (proc event)
                     (derivation--process-sentinel process proc event)))))
          (setf (derivation-process-status process) :running
                (derivation-process-started-at process) (current-time)
                (derivation-process-stoppingp process) nil
                (derivation-process-pending-spec process) nil
                (derivation-process-next-spec process) nil)
          (derivation--process-clear-error process)
          t)
      (error
       (let ((message (error-message-string err)))
         (setf (derivation-process-status process) :failed)
         (derivation--process-set-error process message)
         (when (derivation-process-auto-restart process)
           (derivation--process-schedule-restart process))
         nil)))))

(defun derivation--process-request-stop (process)
  "Ask PROCESS's child to exit without blocking.

Send STOP-SIGNAL, then schedule SIGKILL after STOP-TIMEOUT.  The
sentinel finishes the stop: it cancels the SIGKILL timer, clears
STOPPINGP, and starts NEXT-SPEC when one is pending."
  (let ((proc (derivation-process-process process)))
    (if (and proc (process-live-p proc))
        (progn
          (setf (derivation-process-stoppingp process) t
                (derivation-process-status process) :stopping)
          (ignore-errors
            (signal-process proc (or (derivation-process-stop-signal process)
                                     'SIGTERM)))
          (derivation--process-cancel-stop-timer process)
          (let ((timer nil))
            (setq timer
                  (run-at-time
                   (or (derivation-process-stop-timeout process) 2) nil
                   (lambda ()
                     (when (eq timer (derivation-process-stop-timer process))
                       (setf (derivation-process-stop-timer process) nil)
                       (when (process-live-p proc)
                         (ignore-errors (signal-process proc 'SIGKILL)))))))
            (setf (derivation-process-stop-timer process) timer)))
      (setf (derivation-process-stoppingp process) nil
            (derivation-process-status process) :stopped))))

(defun derivation--process-sentinel (process proc event)
  "Handle PROC's exit for PROCESS.  EVENT is the sentinel string."
  (when (and (eq proc (derivation-process-process process))
             (not (process-live-p proc)))
    (derivation--process-cancel-stop-timer process)
    (let ((next (derivation-process-next-spec process))
          (was-stopping (derivation-process-stoppingp process)))
      (setf (derivation-process-stoppingp process) nil
            (derivation-process-next-spec process) nil)
      (cond
       ((and next (derivation-process-desired process))
        (setf (derivation-process-spec process) next)
        (derivation--process-start process next))
       ((or (not (derivation-process-desired process)) was-stopping)
        (setf (derivation-process-status process) :stopped))
       (t
        (setf (derivation-process-status process) :exited)
        (unless (equal (process-exit-status proc) 0)
          (derivation--process-set-error
           process
           (format "%s: %s" (derivation-process-name process)
                   (string-trim event))))
        (when (derivation-process-auto-restart process)
          (derivation--process-reset-backoff-if-stable process)
          (derivation--process-schedule-restart process)))))))

(defun derivation--process-fire-pending (process)
  "Reconcile PROCESS after its debounce timer fires."
  (when (derivation-process-pending-spec process)
    (setf (derivation-process-pending-spec process) nil)
    (derivation--process-apply process t)))

(defun derivation--process-change (process spec)
  "Apply SPEC to PROCESS, reloading or restarting the child.

With a live child and an ON-CHANGE hook, call the hook with the old
and new spec.  A nil result keeps the child and records SPEC, so the
hook can reload in place.  `:restart' (or t) stops and restarts.
Other results signal an error and leave SPEC uncommitted.  Without a
hook, the child restarts whenever SPEC changes."
  (if (derivation-process-live-p process)
      (let ((hook (derivation-process-on-change process)))
        (cond
         ((null hook)
          (setf (derivation-process-next-spec process) spec)
          (derivation--process-request-stop process))
         (t
          (pcase (funcall hook (derivation-process-spec process) spec)
            ('nil
             (setf (derivation-process-spec process) spec
                   (derivation-process-next-spec process) nil))
            ((or :restart 't)
             (setf (derivation-process-next-spec process) spec)
             (derivation--process-request-stop process))
            (result
             (error "Process :on-change returned %S, expected :restart or nil"
                    result)))))
        t)
    (setf (derivation-process-spec process) spec)
    (derivation--process-start process spec)
    t))

(defun derivation--process-apply (process &optional force)
  "Resolve PROCESS's spec and reconcile.  Return non-nil on change.

FORCE skips the debounce delay; the debounce timer uses it."
  (unless (or (derivation-process-stoppingp process)
              (and (not (derivation-process-desired process))
                   (not (derivation-process-live-p process))
                   (not (derivation-process-pending-spec process))))
    (let ((changed nil))
      (condition-case err
          (pcase-let ((`(,spec . ,inputs) (derivation--resolve-spec process)))
            (setf (derivation-process-inputs process) inputs)
            (when (derivation-process-live-p process)
              (derivation--process-clear-error process))
            (cond
             ((not (derivation-process-desired process))
              (let ((was-live (derivation-process-live-p process))
                    (had-pending (derivation-process-pending-spec process)))
                (derivation--process-cancel-timer process)
                (setf (derivation-process-next-spec process) nil)
                (derivation--process-request-stop process)
                (when (or was-live had-pending)
                  (setq changed t))))
             ((and (derivation-process-pending-spec process)
                   (equal spec (derivation-process-spec process)))
              ;; The spec returned to the running one before the
              ;; debounce fired: drop the pending restart.
              (derivation--process-cancel-timer process)
              (setq changed t))
             ((equal spec (derivation-process-spec process))
              (when (and (derivation-process-auto-restart process)
                         (not (derivation-process-live-p process))
                         (not (derivation-process-restart-timer process)))
                (derivation--process-start process spec)
                (setq changed t)))
             ((and (not force)
                   (derivation-process-spec process)
                   (numberp (derivation-process-debounce process))
                   (> (derivation-process-debounce process) 0))
              (setf (derivation-process-pending-spec process) spec)
              (let ((timer nil))
                (setq timer
                      (run-at-time
                       (derivation-process-debounce process) nil
                       (lambda ()
                         (when (eq timer (derivation-process-timer process))
                           (setf (derivation-process-timer process) nil)
                           (derivation--process-fire-pending process)))))
                (setf (derivation-process-timer process) timer))
              (setq changed t))
             ((derivation-process-live-p process)
              ;; Let the sentinel start SPEC after the old child
              ;; exits: this frees ports and shared resources first.
              (derivation--process-change process spec)
              (setq changed t))
             (t
              (derivation--process-change process spec)
              (setq changed t))))
        (derivation--pending
         (unless (derivation-process-live-p process)
           (setf (derivation-process-status process) :starting)))
        (derivation--failed
         (unless (derivation-process-process process)
           (setf (derivation-process-status process) :failed))
         (derivation--process-set-error
          process (or (cadr err) (error-message-string err))))
        (error
         (unless (derivation-process-process process)
           (setf (derivation-process-status process) :failed))
         (derivation--process-set-error process (error-message-string err))))
      changed)))

(defun derivation--process-teardown (process)
  "Release PROCESS's timers, child and log-buffer hooks.

The child stop finishes asynchronously: a SIGKILL timer fires when
needed, and the sentinel clears the state.  The log buffer may already
be gone by then."
  (setf (derivation-process-desired process) nil
        (derivation-process-next-spec process) nil)
  (derivation--process-cancel-timer process)
  (derivation--process-cancel-restart-timer process)
  (derivation--process-request-stop process)
  (let ((log (derivation-process-log process))
        (hook (derivation-process-kill-hook process)))
    (when (buffer-live-p log)
      (with-current-buffer log
        (when hook
          (remove-hook 'kill-buffer-hook hook t))
        (setq-local derivation--source nil)
        (setq-local buffer-stale-function nil)
        (setq-local revert-buffer-function nil)))))

(defun derivation-process-start (process)
  "Enable PROCESS and start its child, resolving the spec if needed."
  (derivation--process-cancel-timer process)
  (derivation--process-cancel-restart-timer process)
  (setf (derivation-process-desired process) t)
  (condition-case nil
      (pcase-let ((`(,spec . ,inputs) (derivation--resolve-spec process)))
        (setf (derivation-process-inputs process) inputs)
        (cond
         ((not (derivation-process-live-p process))
          (setf (derivation-process-spec process) spec)
          (derivation--process-start process spec))
         ((derivation-process-stoppingp process)
          ;; The child is already on its way out: start SPEC after it.
          (setf (derivation-process-next-spec process) spec))
         ((not (equal spec (derivation-process-spec process)))
          (setf (derivation-process-next-spec process) spec)
          (derivation--process-request-stop process))))
    (derivation--pending
     (unless (derivation-process-live-p process)
       (setf (derivation-process-status process) :starting))))
  process)

(defun derivation-process-stop (process)
  "Disable PROCESS and ask its child to stop, without blocking.

STOP-SIGNAL fires now, SIGKILL after STOP-TIMEOUT.  A later
`derivation-process-start' re-enables the process.  The process deriver
leaves it stopped while it is disabled."
  (setf (derivation-process-desired process) nil
        (derivation-process-next-spec process) nil)
  (derivation--process-cancel-timer process)
  (derivation--process-cancel-restart-timer process)
  (derivation--process-request-stop process)
  process)

(defun derivation-process-restart (process)
  "Restart PROCESS from a freshly resolved spec, without blocking.

The old child gets STOP-SIGNAL now.  Its replacement starts from the
sentinel after the old child exits."
  (setf (derivation-process-desired process) t)
  (derivation--process-cancel-timer process)
  (derivation--process-cancel-restart-timer process)
  (condition-case nil
      (pcase-let ((`(,spec . ,inputs) (derivation--resolve-spec process)))
        (setf (derivation-process-inputs process) inputs)
        (if (derivation-process-live-p process)
            (progn
              (setf (derivation-process-next-spec process) spec)
              (derivation--process-request-stop process))
          (setf (derivation-process-spec process) spec)
          (derivation--process-start process spec)))
    (derivation--pending
     (unless (derivation-process-live-p process)
       (setf (derivation-process-status process) :starting))))
  process)

;;;###autoload
(cl-defun derivation-make-process (&key name command directory environment
                                        (auto-restart t)
                                        (backoff '(0.5 1 2 5))
                                        (stop-signal 'SIGTERM)
                                        (stop-timeout 2)
                                        (debounce 0)
                                        on-change)
  "Create a long-running child process derived from a live spec.

COMMAND is a non-empty list (PROGRAM ARG...).  Each COMMAND element
may be a string, a `derivation-input' or a function returning one.
DIRECTORY may be a string, a `derivation-input' or a function.
ENVIRONMENT is a list of \"VAR=VALUE\" strings or (VAR . VALUE)
conses; VALUE may be a string, a `derivation-input' or a function,
and a nil VALUE unsets VAR.  DIRECTORY defaults to the
`default-directory' at creation.

Resolved inputs are recorded, so expensive values (such as
\='(\"nix\" \"build\" \"--no-out-link\" \".#docs\")) pull only when their
own stamp changes.

SPEC is the tuple of resolved command, program identity, directory
and environment.  The process restarts when SPEC changes (compared
with `equal').  Program identity covers the executable's truename,
inode, size and mtime, so replacing or retargeting the binary
restarts the child even when argv stays the same.  The same restart
happens after `derivation-process-restart'.

AUTO-RESTART (default t) restarts an unexpectedly exited child with
delays from BACKOFF (seconds, default 0.5s, 1s, 2s, 5s, capped).
Backoff resets after a run longer than the cap.  Every stop is
asynchronous: STOP-SIGNAL (default SIGTERM) fires now, SIGKILL
follows after STOP-TIMEOUT seconds (default 2), and the replacement
starts from the sentinel after the old child exits, so ports and
shared resources free first.  DEBOUNCE delays SPEC-change restarts
by that many seconds \(default 0, immediate).

ON-CHANGE is called with the old and new resolved specs when SPEC
changes while the child runs.  Return nil to keep the child and
reload it in place (for example with SIGHUP); the new SPEC is then
recorded.  Return `:restart' (or t) to stop and start it.  Other
results signal an error and leave the old SPEC.  Without ON-CHANGE
the default is to restart.

The deriver is registered automatically and reconciles on the
`derivation-run-hooks' schedule.  The child's stdout and stderr go to
a hidden log buffer with `derivation-mode-line' support; killing that
buffer stops the process.  `derivation-unregister' accepts the
returned handle and asks the child to stop; the child can outlive the
call by up to STOP-TIMEOUT.  STATUS `:stopping' means the exit is in
flight.

Returns a `derivation-process' handle.  Use `derivation-process-process',
`derivation-process-status', `derivation-process-log',
`derivation-process-live-p' and `derivation-process-exit-status' to
inspect it, and `derivation-process-start', `derivation-process-stop'
and `derivation-process-restart' to control it."
  (unless (and (listp command) command)
    (error "derivation-make-process: COMMAND must be a non-empty list"))
  (when (and on-change (not (functionp on-change)))
    (error "derivation-make-process: ON-CHANGE must be a function or nil"))
  (let* ((name (or name
                   (let ((program (car command)))
                     (if (stringp program)
                         (file-name-nondirectory program)
                       "derivation-process"))))
         (log (generate-new-buffer
               (format " *derivation-process-%s*" name)))
         (handle (derivation--process-create
                  :name name
                  :command command
                  :directory (cond ((null directory) default-directory)
                                   ((stringp directory)
                                    (expand-file-name directory))
                                   (t directory))
                  :environment environment
                  :log log
                  :desired t
                  :status :stopped
                  :restart-count 0
                  :auto-restart auto-restart
                  :backoff backoff
                  :stop-signal stop-signal
                  :stop-timeout stop-timeout
                  :debounce debounce
                  :on-change on-change))
         (deriver (lambda () (derivation--process-apply handle)))
         (kill-hook (lambda () (derivation-unregister handle))))
    (setf (derivation-process-deriver handle) deriver
          (derivation-process-kill-hook handle) kill-hook)
    (with-current-buffer log
      (erase-buffer)
      (goto-char (point-max))
      (add-hook 'kill-buffer-hook kill-hook nil t))
    (derivation--install-target-hooks
     log name
     (lambda (&optional _)
       (not (derivation-process-live-p handle)))
     (lambda () (derivation-process-restart handle)))
    (derivation-register deriver
                         (lambda () (derivation--process-teardown handle)))
    (derivation--process-apply handle)
    handle))

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
converges in a single call.  Re-runs bypass memoization.

Asynchronous command derivers start a fresh command and return before
it finishes; their targets update on a later pass."
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
