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
;;   ;; Run derivations on idle.
;;   (run-with-idle-timer 0.1 t #'derivation-run-hooks)
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
  "List of (DERIVER . CLEANUP-FN) records, in registration order.
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
The hook removes DERIVER's record from `derivation--storage' when the
buffer is killed (kill-buffer runs the hook with the buffer current, so
a buffer-local hook fires directly).  Returns a cleanup function that
uninstalls the hooks."
  (let ((hook
         (lambda ()
           (setq derivation--storage
                 (delete (assq deriver derivation--storage)
                         derivation--storage)))))
    (dolist (buf bufs)
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (add-hook 'kill-buffer-hook hook nil t))))
    (lambda ()
      (dolist (buf bufs)
        (when (buffer-live-p buf)
          (with-current-buffer buf
            (remove-hook 'kill-buffer-hook hook t)))))))

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
commands is captured in a hidden buffer."
  (let* ((buf (if (bufferp frombuf) frombuf (get-buffer frombuf)))
         (tbuf (if (bufferp tobuf) tobuf (get-buffer tobuf)))
         (last-tick -1)
         (errbuf (generate-new-buffer
                  (format " *derivation-err-%s*" (gensym))))
         inner)
    (unless (buffer-live-p tbuf)
      (error "derivation-make-deriver: target buffer is not live"))
    (unless (buffer-live-p buf)
      (error "derivation-make-deriver: source buffer is not live"))
    (setq inner
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
                (`(ok . ,text)
                 (with-current-buffer tbuf
                   (with-silent-modifications
                     (erase-buffer)
                     (insert text))
                   (setq-local derivation--error nil))
                 (with-current-buffer errbuf
                   (with-silent-modifications (erase-buffer))))
                (`(err . ,msg)
                 (with-current-buffer errbuf
                   (with-silent-modifications
                     (erase-buffer)
                     (insert msg)))
                 (with-current-buffer tbuf
                   (setq-local derivation--error msg))))
              t)))
    (let* ((deriver
            ;; Return the caching wrapper: dirty-check then maybe call inner.
            (lambda ()
              (when (and (buffer-live-p buf) (buffer-live-p tbuf))
                (let ((tick (buffer-chars-modified-tick buf)))
                  (unless (= tick last-tick)
                    (setq last-tick tick)
                    (funcall inner))))))
           (cleanup
            (derivation--register-kill-hooks deriver (list buf tbuf))))
      (with-current-buffer tbuf
        (setq-local derivation--source (cons buf inner)))
      (derivation-register deriver cleanup)
      deriver)))

;;; Generic data derivation

(defconst derivation--unset (make-symbol "derivation--unset")
  "Sentinel distinguishing \"never run\" from any real value.")

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
  (let ((last-stamp derivation--unset)
        (last-data derivation--unset))
    (lambda ()
      (let* ((poll (null stamp-fn))
             (stamp (unless poll (funcall stamp-fn)))
             (dirty (or poll
                        (eq last-stamp derivation--unset)
                        (not (equal stamp last-stamp)))))
        (when dirty
          (setq last-stamp stamp)
          (let ((data (funcall pull-fn)))
            (unless (equal data last-data)
              (setq last-data (copy-tree data t))
              (funcall push-fn data)
              t)))))))

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
mutations that the watcher would miss."
  (let* ((entry (gethash fromvar derivation--var-watch-table))
         (last-gen -1)
         (last-value nil)
         (deriver nil))
    ;; Install or bump refcount.
    (if entry
        (cl-incf (cdr entry))
      (puthash fromvar (cons 0 1) derivation--var-watch-table)
      (add-variable-watcher fromvar #'derivation--var-bump))
    (setq deriver
          (lambda ()
            (let ((cur-gen (car (gethash fromvar derivation--var-watch-table)))
                  (cur-val (symbol-value fromvar)))
              (when (or (/= cur-gen last-gen)
                        (not (equal cur-val last-value)))
                (setq last-gen cur-gen
                      last-value (copy-tree cur-val t))
                (set tovar (funcall func cur-val))))))
    (derivation-register deriver)
    deriver))

;;; Generic tree walk

(cl-defgeneric derivation--node-children (node)
  "Return the children of NODE as a list, or nil.

The default method handles EIEIO objects that have a `children'
slot.  Additional methods can be defined for hash tables, alists,
lists, vectors, etc. — enabling new deriver types (map-filter,
seq-filter, etc.) without changing the tree walker."
  (when (and (fboundp 'eieio-object-p)
             (eieio-object-p node)
             (with-no-warnings (slot-exists-p node 'children)))
    (with-no-warnings (slot-value node 'children))))

(defun derivation--walk-tree (root predicate &optional skip-root)
  "Traverse tree from ROOT, collecting nodes matching PREDICATE.
Uses `derivation--node-children' to recurse into each node.
Returns matching nodes in preorder.  When SKIP-ROOT is non-nil,
PREDICATE is not applied to ROOT itself, only to its descendants."
  (let ((results nil))
    (cl-labels ((walk (node)
                  (when (funcall predicate node)
                    (push node results))
                  (dolist (child (derivation--node-children node))
                    (walk child))))
      (if skip-root
          (dolist (child (derivation--node-children root))
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
  (let* ((buf (if (bufferp frombuf) frombuf (get-buffer frombuf)))
         (tbuf (if (bufferp tobuf) tobuf (get-buffer tobuf)))
         (last-tick -1)
         inner)
    (unless (buffer-live-p tbuf)
      (error "derivation-make-section-filter: target buffer is not live"))
    (unless (buffer-live-p buf)
      (error "derivation-make-section-filter: source buffer is not live"))
    (setq inner
          (lambda ()
            (let ((text
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
                       (buffer-string)))))
              (with-current-buffer tbuf
                (with-silent-modifications
                  (erase-buffer)
                  (insert text)))
              t)))
    (let* ((deriver
            ;; Return the caching wrapper: dirty-check then maybe call inner.
            (lambda ()
              (when (and (buffer-live-p buf) (buffer-live-p tbuf))
                (let ((tick (buffer-chars-modified-tick buf)))
                  (unless (= tick last-tick)
                    (setq last-tick tick)
                    (funcall inner))))))
           (cleanup
            (derivation--register-kill-hooks deriver (list buf tbuf))))
      (with-current-buffer tbuf
        (setq-local derivation--source (cons buf inner)))
      (derivation-register deriver cleanup)
      deriver)))

(defvar-local derivation--source nil
  "When non-nil, this buffer is a derivation target.
Value is (SOURCE . INNER-TRANSFORM-FUNCTION).  SOURCE is a buffer
or a string label (data derivations have no source buffer); it is
shown by `derivation-mode-line' and used by
`derivation-jump-to-source'.  The inner function bypasses
memoization, used by `derivation-rerun'.")

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
    ;; Collect the chain of buffers, current → upstream.
    (while (and buf (buffer-live-p buf)
                (not (member buf chain)))
      (push buf chain)
      (setq buf (car (buffer-local-value 'derivation--source buf))))
    ;; Re-run upstream→downstream (reverse of the chain).
    (dolist (b (reverse chain))
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
        (records (copy-tree derivation--storage)))
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
