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
;; Package-Requires: ((emacs "30.1"))

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
;;          (make-deriver
;;           "jq"                               ; command
;;           (get-buffer-create "foo.json")      ; source
;;           (get-buffer-create "*json-out*")    ; target
;;           "."                                 ; extra args to jq
;;           "-C")))
;;
;;   ;; Derive *yaml-out* from *json-out* (a pipeline of two buffers).
;;   (push (make-deriver
;;          "yq"
;;          (get-buffer-create "*json-out*")
;;          (get-buffer-create "*yaml-out*")
;;          "-p" "json" "-o" "yaml")
;;         derivation--storage)
;;
;;   ;; Derive *baz* from *foo* via `base64-encode-string'.
;;   (push (make-deriver
;;          #'base64-encode-string
;;          (get-buffer-create "*foo*")
;;          (get-buffer-create "*baz*"))
;;         derivation--storage)
;;   ;; Derive variable `baz' from `foo' via `length'.
;;   (push (make-var-deriver #'length 'foo 'baz)
;;         derivation--storage)
;;
;;   ;; Run derivations on idle.
;;   (run-with-idle-timer 0.1 t #'run-hooks-derivation)
;;
;; Because derivations are memoized, calling them repeatedly when the
;; source hasn't changed is a no-op — ideal for idle timers.

;;; Code:

(require 'cl-lib)

(defun memoize-by-buffer-contents--wrap-buf (func buf)
  "Return a memoized version of FUNC that invalidates when BUF is modified.
The cache key is (BUF . BUFFER-MODIFIED-TICK)."
  (let ((memoization-table (make-hash-table :test 'equal :weakness 'key)))
    (lambda (&rest args)
      (let* ((buftick (cons buf (buffer-chars-modified-tick buf)))
             (memokey (cons buftick args))
             (value (gethash memokey memoization-table)))
        (if (null value)
            (puthash memokey (apply func args) memoization-table)
          value)))))

(defvar derivation--storage nil
  "List of deriver functions to run via `run-hooks-derivation'.
Each element should be a function returned by `make-deriver' or
`make-var-deriver'.")

(defun make-deriver (command frombuf tobuf &rest args)
  "Create a memoized function that derives TOBUF from FROMBUF via COMMAND.

FROMBUF and TOBUF may be buffers or buffer names.

COMMAND may be:
  - A string: an external program run via `call-process-region'.
    Extra ARGS are passed as arguments to the command.
  - A function: called with the source buffer contents as its only
    argument.  ARGS are ignored.

The returned function takes no arguments.  When called, it transforms
the contents of FROMBUF through COMMAND and replaces the contents of
TOBUF with the output.  The result is memoized: if FROMBUF hasn't been
modified since the last call, TOBUF is left untouched."
  (let ((tracker (gensym "derivation--tracker-"))
        (buf (if (bufferp frombuf) frombuf (get-buffer frombuf)))
        inner)
    (fset tracker
          (lambda ()
            (let ((content (with-current-buffer buf
                             (buffer-substring-no-properties
                              (point-min) (point-max)))))
              (with-current-buffer tobuf
                (with-silent-modifications
                  (erase-buffer)
                  (insert
                   (cl-typecase command
                     (string
                      (with-temp-buffer
                        (let* ((coding '(no-conversion . no-conversion))
                               (default-process-coding-system coding)
                               (exitcode
                                (apply #'call-process-region
                                       content nil command nil
                                       (list (current-buffer) t) nil
                                       args)))
                          (if (zerop exitcode)
                              (string-trim (buffer-string))
                            (buffer-string)))))
                     (function
                      (funcall command content))
                     (t
                      (error "COMMAND must be a string or function, got %S"
                             (type-of command))))))))
            t))
    (setq inner (symbol-function tracker))
    (fset tracker
          (memoize-by-buffer-contents--wrap-buf inner buf))
    (with-current-buffer tobuf
      (setq-local derivation--source (cons buf inner)))
    tracker))

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
  (let ((entry (gethash symbol derivation--var-watch-table)))
    (when entry
      (cl-incf (car entry)))))

;;;###autoload
(defun make-var-deriver (func fromvar tovar)
  "Create a memoized function that derives TOVAR from FROMVAR via FUNC.

FUNC is called with the value of FROMVAR as its sole argument.
The return value is assigned to TOVAR via `set'.

The returned function takes no arguments and is compatible with
`run-hooks-derivation': just push it onto `derivation--storage'.

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
            (let ((cur-gen (car (gethash fromvar derivation--var-watch-table
                                         '(0 . 0))))
                  (cur-val (symbol-value fromvar)))
              (when (or (/= cur-gen last-gen)
                        (not (equal cur-val last-value)))
                (setq last-gen cur-gen
                      last-value (copy-tree cur-val))
                (set tovar (funcall func cur-val))))))
    deriver))

(defvar-local derivation--source nil
  "When non-nil, this buffer is a derivation target.
Value is (SOURCE-BUFFER . MEMOIZED-DERIVER).")

(defvar derivation-mode-line
  '(:eval (when derivation--source
            (propertize " ⟳"
                        'help-echo (format "derived from %s"
                                           (buffer-name (car derivation--source)))
                        'mouse-face 'mode-line-highlight
                        'local-map (let ((map (make-sparse-keymap)))
                                     (define-key map [mode-line mouse-1]
                                                 #'derivation-jump-to-source)
                                     map))))
  "Mode-line construct showing derivation status.
Add to `mode-line-format' to see which buffers are derived.
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

(defun run-hooks-derivation ()
  "Run all derivers in `derivation--storage'.
Intended to be called from an idle timer or manually."
  (interactive)
  (run-hooks 'derivation--storage))

(provide 'derivation)
;;; derivation.el ends here
