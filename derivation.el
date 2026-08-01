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
;;   (setq derivation--storage
;;         (list
;;          (derivation-make-deriver
;;           "jq"                               ; command
;;           (get-buffer-create "foo.json")      ; source
;;           (get-buffer-create "*json-out*")    ; target
;;           "."                                 ; extra args to jq
;;           "-C")))
;;
;;   ;; Derive *yaml-out* from *json-out* (a pipeline of two buffers).
;;   (push (derivation-make-deriver
;;          "yq"
;;          (get-buffer-create "*json-out*")
;;          (get-buffer-create "*yaml-out*")
;;          "-p" "json" "-o" "yaml")
;;         derivation--storage)
;;
;;   ;; Derive *baz* from *foo* via `base64-encode-string'.
;;   (push (derivation-make-deriver
;;          #'base64-encode-string
;;          (get-buffer-create "*foo*")
;;          (get-buffer-create "*baz*"))
;;         derivation--storage)
;;   ;; Derive variable `baz' from `foo' via `length'.
;;   (push (derivation-make-var-deriver #'length 'foo 'baz)
;;         derivation--storage)
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

(defvar derivation--storage nil
  "List of deriver functions to run via `derivation-run-hooks'.
Each element should be a function returned by `derivation-make-deriver' or
`derivation-make-var-deriver'.")

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
    (with-current-buffer tbuf
      (setq-local derivation--source (cons buf inner)))
    ;; Return the caching wrapper: dirty-check then maybe call inner.
    (lambda ()
      (when (and (buffer-live-p buf) (buffer-live-p tbuf))
        (let ((tick (buffer-chars-modified-tick buf)))
          (unless (= tick last-tick)
            (setq last-tick tick)
            (funcall inner)))))))

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
`derivation-run-hooks': just push it onto `derivation--storage'.

Memoization is hybrid: a variable watcher provides a fast \"not
dirty\" check, and an `equal' value comparison catches in-place
mutations that the watcher would miss.

When the returned deriver function is garbage-collected, the
variable watcher on FROMVAR is automatically removed (once no
other derivers reference it)."
  (let* ((entry (gethash fromvar derivation--var-watch-table))
         (last-gen -1)
         (last-value nil)
         (cleanup
          (lambda ()
            (let ((entry (gethash fromvar derivation--var-watch-table)))
              (when entry
                (cl-decf (cdr entry))
                (when (zerop (cdr entry))
                  (remove-variable-watcher fromvar #'derivation--var-bump)
                  (remhash fromvar derivation--var-watch-table))))))
         ;; make-finalizer returns a token whose GC triggers cleanup.
         ;; We capture the token in deriver's closure so it lives
         ;; exactly as long as deriver does.
         (finalizer-token (make-finalizer cleanup))
         (deriver nil))
    ;; Install or bump refcount.
    (if entry
        (cl-incf (cdr entry))
      (puthash fromvar (cons 0 1) derivation--var-watch-table)
      (add-variable-watcher fromvar #'derivation--var-bump))
    (setq deriver
          (lambda ()
            (ignore finalizer-token)
            (let ((cur-gen (car (gethash fromvar derivation--var-watch-table)))
                  (cur-val (symbol-value fromvar)))
              (when (or (/= cur-gen last-gen)
                        (not (equal cur-val last-value)))
                (setq last-gen cur-gen
                      last-value (copy-tree cur-val t))
                (set tovar (funcall func cur-val))))))
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
`derivation-run-hooks': just push it onto `derivation--storage'.

Memoization is keyed on FROMBUF's buffer-chars-modified-tick.

Example that filters magit-process to show only failed commands:

  (push (derivation-make-section-filter
         (lambda (section)
           (let ((proc (slot-value section \\='value)))
             (and (processp proc)
                  (numberp (process-exit-status proc))
                  (/= 0 (process-exit-status proc)))))
         (magit-process-buffer t)
         (get-buffer-create \"*magit-failures*\"))
        derivation--storage)"
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
    (with-current-buffer tbuf
      (setq-local derivation--source (cons buf inner)))
    (lambda ()
      (when (and (buffer-live-p buf) (buffer-live-p tbuf))
        (let ((tick (buffer-chars-modified-tick buf)))
          (unless (= tick last-tick)
            (setq last-tick tick)
            (funcall inner)))))))

(defvar-local derivation--source nil
  "When non-nil, this buffer is a derivation target.
Value is (SOURCE-BUFFER . INNER-TRANSFORM-FUNCTION).
The inner function bypasses the tick cache, used by `derivation-rerun'.")

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
                                               (buffer-name
                                                (car derivation--source))
                                               derivation--error)
                            'mouse-face 'mode-line-highlight
                            'local-map derivation--mode-line-map)
              (propertize " ⟳"
                          'help-echo (format "derived from %s"
                                             (buffer-name
                                              (car derivation--source)))
                          'mouse-face 'mode-line-highlight
                          'local-map derivation--mode-line-map))))
  "Mode-line construct showing derivation status.
Add to `mode-line-format' to see which buffers are derived.
Shows \"⟳\" normally, \"⟳!\" in error face when the last run failed.
Click to jump to the source buffer.")

(defun derivation-rerun ()
  "Re-run the derivation that produced the current buffer."
  (interactive)
  (if derivation--source
      (funcall (cdr derivation--source))
    (user-error "Buffer is not a derivation target")))

(defun derivation-jump-to-source ()
  "Switch to the source buffer of this derivation target."
  (interactive)
  (if derivation--source
      (switch-to-buffer (car derivation--source))
    (user-error "Buffer is not a derivation target")))

;;;###autoload
(defun derivation-run-hooks ()
  "Run all derivers in `derivation--storage'.
Intended to be called from an idle timer or manually.
Errors in individual derivers are caught and reported without
aborting the remaining derivers."
  (interactive)
  (dolist (d derivation--storage)
    (condition-case err
        (funcall d)
      (error
       (message "derivation: error in deriver: %s"
                (error-message-string err))))))

(provide 'derivation)
;;; derivation.el ends here
