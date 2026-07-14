;;; derivation.el --- Live buffer derivation via external commands -*- lexical-binding: t -*-

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

;; `derivation' creates derived buffers: buffers whose content is the
;; result of piping another buffer through an external command.
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
;;   ;; Run derivations on idle.
;;   (run-with-idle-timer 0.1 t #'run-hooks-derivation)
;;
;; Because the deriver is memoized per source-buffer tick, calling it
;; repeatedly when the source hasn't changed is a no-op — ideal for
;; idle timers.

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
Each element should be a function returned by `make-deriver'.")

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
        (buf (if (bufferp frombuf) frombuf (get-buffer frombuf))))
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
    (fset tracker
          (memoize-by-buffer-contents--wrap-buf
           (symbol-function tracker) buf))
    tracker))

(defun run-hooks-derivation ()
  "Run all derivers in `derivation--storage'.
Intended to be called from an idle timer or manually."
  (interactive)
  (run-hooks 'derivation--storage))

(provide 'derivation)
;;; derivation.el ends here
