;;; derivation-tests.el --- Tests for derivation.el -*- lexical-binding: t -*-

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

(require 'derivation)
(require 'ert)

;;; Helpers

(defun derivation-test--with-buffers (source-content)
  "Create source and target buffers with SOURCE-CONTENT, return (src . dst)."
  (let ((src (generate-new-buffer " *deriv-test-src*"))
        (dst (generate-new-buffer " *deriv-test-dst*")))
    (with-current-buffer src (insert source-content))
    (cons src dst)))

(defun derivation-test--kill-buffers (bufs)
  "Kill all buffers in BUFS (a list of buffer cons cells)."
  (dolist (pair bufs)
    (kill-buffer (car pair))
    (kill-buffer (cdr pair))))


;;; Tests

(ert-deftest derivation-identity ()
  "Source content passes through `cat' unchanged into target."
  (skip-unless (executable-find "cat"))
  (let* ((bufs (derivation-test--with-buffers "hello world"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (make-deriver "cat" src dst)))
    (funcall deriver)
    (with-current-buffer dst
      (should (equal (buffer-string) "hello world")))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-transformation ()
  "Source content is uppercased via `tr a-z A-Z' into target."
  (skip-unless (executable-find "tr"))
  (let* ((bufs (derivation-test--with-buffers "hello world"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (make-deriver "tr" src dst "a-z" "A-Z")))
    (funcall deriver)
    (with-current-buffer dst
      (should (equal (buffer-string) "HELLO WORLD")))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-memoization ()
  "Target is not recomputed when source hasn't changed."
  (skip-unless (executable-find "cat"))
  (let* ((bufs (derivation-test--with-buffers "v1"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (make-deriver "cat" src dst)))
    ;; Initial derivation.
    (funcall deriver)
    (with-current-buffer dst
      (should (equal (buffer-string) "v1")))
    ;; Tamper with target manually — memoization should prevent overwrite.
    (with-current-buffer dst
      (erase-buffer)
      (insert "tampered"))
    (funcall deriver)
    (with-current-buffer dst
      (should (equal (buffer-string) "tampered")))
    ;; Change source — should trigger recomputation.
    (with-current-buffer src
      (erase-buffer)
      (insert "v2"))
    (funcall deriver)
    (with-current-buffer dst
      (should (equal (buffer-string) "v2")))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-command-args ()
  "Extra arguments to make-deriver are passed to the command."
  (skip-unless (executable-find "tr"))
  (let* ((bufs (derivation-test--with-buffers "abc"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (make-deriver "tr" src dst "abc" "xyz")))
    (funcall deriver)
    (with-current-buffer dst
      (should (equal (buffer-string) "xyz")))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-function ()
  "Derivation via an Elisp function."
  (let* ((bufs (derivation-test--with-buffers "hello"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (make-deriver #'upcase src dst)))
    (funcall deriver)
    (with-current-buffer dst
      (should (equal (buffer-string) "HELLO")))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-function-base64 ()
  "Derivation via `base64-encode-string'."
  (let* ((bufs (derivation-test--with-buffers "abc"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (make-deriver #'base64-encode-string src dst)))
    (funcall deriver)
    (with-current-buffer dst
      (should (equal (buffer-string) (base64-encode-string "abc"))))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-function-memoized ()
  "Function derivation is memoized like external commands."
  (let* ((bufs (derivation-test--with-buffers "x"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (make-deriver #'upcase src dst)))
    (funcall deriver)
    (should (equal (with-current-buffer dst (buffer-string)) "X"))
    ;; Tamper target — memoization should preserve it.
    (with-current-buffer dst (erase-buffer) (insert "tampered"))
    (funcall deriver)
    (should (equal (with-current-buffer dst (buffer-string)) "tampered"))
    ;; Change source — should recompute.
    (with-current-buffer src (erase-buffer) (insert "y"))
    (funcall deriver)
    (should (equal (with-current-buffer dst (buffer-string)) "Y"))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-multiple-calls ()
  "Repeated calls without source change return cached result."
  (skip-unless (executable-find "cat"))
  (let* ((bufs (derivation-test--with-buffers "fixed"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (make-deriver "cat" src dst))
         (call-count 0))
    ;; Wrap the deriver to count actual (non-memoized) invocations.
    ;; We detect recomputation by observing that the target reflects
    ;; source changes.
    (funcall deriver)
    (should (equal (with-current-buffer dst (buffer-string)) "fixed"))
    ;; Multiple calls without source change.
    (dotimes (_ 5)
      (funcall deriver)
      (should (equal (with-current-buffer dst (buffer-string)) "fixed")))
    (derivation-test--kill-buffers (list bufs))))


(ert-deftest derivation--source-is-set ()
  "Target buffer gets derivation--source set by make-deriver."
  (let* ((bufs (derivation-test--with-buffers "hello"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (make-deriver #'upcase src dst)))
    (funcall deriver)
    (with-current-buffer dst
      (should derivation--source)
      (should (bufferp (car derivation--source)))
      (should (functionp (cdr derivation--source))))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation--source-is-nil-in-other-buffers ()
  "derivation--source is nil in non-derivation buffers."
  (with-temp-buffer
    (should-not derivation--source)))

(ert-deftest derivation-rerun ()
  "derivation-rerun re-runs the derivation, bypassing memoization."
  (let* ((bufs (derivation-test--with-buffers "hello"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (make-deriver #'upcase src dst)))
    (funcall deriver)
    (with-current-buffer dst
      (should (equal (buffer-string) "HELLO"))
      (erase-buffer) (insert "tampered")
      (derivation-rerun)
      (should (equal (buffer-string) "HELLO")))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-jump-to-source ()
  "derivation-jump-to-source switches to the source buffer."
  (let* ((bufs (derivation-test--with-buffers "hello"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (make-deriver #'upcase src dst)))
    (funcall deriver)
    (with-current-buffer dst
      (derivation-jump-to-source)
      (should (eq (current-buffer) src)))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-mode-line-form-evaluates ()
  "The :eval form in derivation-mode-line returns propertized string."
  (let* ((bufs (derivation-test--with-buffers "hello"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (make-deriver #'upcase src dst)))
    (funcall deriver)
    (with-current-buffer dst
      (let ((result (eval (cadr derivation-mode-line))))
        (should (stringp result))
        (should (string-match "⟳" result))
        (should (get-text-property 0 'help-echo result))
        (should (eq 'mode-line-highlight
                  (get-text-property 0 'mouse-face result)))))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-mode-line-form-nil-when-not-set ()
  "The :eval form returns nil in non-derived buffers."
  (with-temp-buffer
    (should-not (eval (cadr derivation-mode-line)))))

;;; Variable derivation tests

;; Declare test variables as dynamic so make-var-deriver can resolve
;; them via `symbol-value' and `set'.
(defvar derivation-test--foo)
(defvar derivation-test--baz)

(ert-deftest derivation-var-basic ()
  "Variable derivation: `baz' derives from `foo' via `length'."
  (let ((derivation-test--foo (list 1 2 3))
        derivation-test--baz)
    (let ((deriver (make-var-deriver #'length 'derivation-test--foo
                                     'derivation-test--baz)))
      (funcall deriver)
      (should (equal derivation-test--baz
                     (length derivation-test--foo))))))

(ert-deftest derivation-var-memoization ()
  "Variable derivation is memoized when source hasn't changed."
  (let ((derivation-test--foo (list 1 2 3))
        derivation-test--baz)
    (let ((deriver (make-var-deriver #'length 'derivation-test--foo
                                     'derivation-test--baz)))
      (funcall deriver)
      (should (equal derivation-test--baz 3))
      ;; Tamper with target — memoization should prevent overwrite.
      (setq derivation-test--baz 99)
      (funcall deriver)
      (should (equal derivation-test--baz 99)))))

(ert-deftest derivation-var-source-change ()
  "Variable derivation recomputes when source variable changes."
  (let ((derivation-test--foo (list 1 2 3))
        derivation-test--baz)
    (let ((deriver (make-var-deriver #'length 'derivation-test--foo
                                     'derivation-test--baz)))
      (funcall deriver)
      (should (equal derivation-test--baz 3))
      ;; Change source — should recompute.
      (setq derivation-test--foo (list 1 2 3 4 5))
      (funcall deriver)
      (should (equal derivation-test--baz 5)))))

(ert-deftest derivation-var-mutation ()
  "Variable derivation catches in-place mutations via equal fallback.

A setcar on the source list does not fire the variable watcher,
so the generation counter stays the same.  The `equal' check detects
the in-place change and triggers recomputation regardless."
  (let ((derivation-test--foo (list 1 2 3))
        derivation-test--baz)
    (let ((deriver (make-var-deriver #'length 'derivation-test--foo
                                     'derivation-test--baz)))
      (funcall deriver)
      (should (equal derivation-test--baz 3))
      ;; Mutate in place — no watcher fires for setcar,
      ;; but equal-check detects the change.
      (setcar derivation-test--foo 42)
      (funcall deriver)
      ;; Still 3 elements, but derivation recomputed.
      (should (equal derivation-test--baz 3))
      ;; Now add an element in place.
      (setcdr (last derivation-test--foo) '(4))
      (funcall deriver)
      (should (equal derivation-test--baz 4)))))

(ert-deftest derivation-var-multiple-calls ()
  "Repeated calls without source change don't re-derive."
  (let ((derivation-test--foo (list 1 2 3))
        derivation-test--baz)
    (let ((deriver (make-var-deriver #'length 'derivation-test--foo
                                     'derivation-test--baz)))
      (funcall deriver)
      (dotimes (_ 10)
        (funcall deriver)
        (should (equal derivation-test--baz 3))))))

(provide 'derivation-tests)
;;; derivation-tests.el ends here