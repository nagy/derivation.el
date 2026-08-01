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


;;; Buffer derivation tests

(ert-deftest derivation-identity ()
  "Source content passes through `cat' unchanged into target."
  (skip-unless (executable-find "cat"))
  (let* ((bufs (derivation-test--with-buffers "hello world"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver "cat" src dst)))
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
         (deriver (derivation-make-deriver "tr" src dst "a-z" "A-Z")))
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
         (deriver (derivation-make-deriver "cat" src dst)))
    (funcall deriver)
    (with-current-buffer dst
      (should (equal (buffer-string) "v1")))
    (with-current-buffer dst
      (erase-buffer)
      (insert "tampered"))
    (funcall deriver)
    (with-current-buffer dst
      (should (equal (buffer-string) "tampered")))
    (with-current-buffer src
      (erase-buffer)
      (insert "v2"))
    (funcall deriver)
    (with-current-buffer dst
      (should (equal (buffer-string) "v2")))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-command-args ()
  "Extra arguments to derivation-make-deriver are passed to the command."
  (skip-unless (executable-find "tr"))
  (let* ((bufs (derivation-test--with-buffers "abc"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver "tr" src dst "abc" "xyz")))
    (funcall deriver)
    (with-current-buffer dst
      (should (equal (buffer-string) "xyz")))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-function ()
  "Derivation via an Elisp function."
  (let* ((bufs (derivation-test--with-buffers "hello"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver #'upcase src dst)))
    (funcall deriver)
    (with-current-buffer dst
      (should (equal (buffer-string) "HELLO")))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-function-base64 ()
  "Derivation via `base64-encode-string'."
  (let* ((bufs (derivation-test--with-buffers "abc"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver #'base64-encode-string src dst)))
    (funcall deriver)
    (with-current-buffer dst
      (should (equal (buffer-string) (base64-encode-string "abc"))))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-function-memoized ()
  "Function derivation is memoized like external commands."
  (let* ((bufs (derivation-test--with-buffers "x"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver #'upcase src dst)))
    (funcall deriver)
    (should (equal (with-current-buffer dst (buffer-string)) "X"))
    (with-current-buffer dst (erase-buffer) (insert "tampered"))
    (funcall deriver)
    (should (equal (with-current-buffer dst (buffer-string)) "tampered"))
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
         (deriver (derivation-make-deriver "cat" src dst)))
    (funcall deriver)
    (should (equal (with-current-buffer dst (buffer-string)) "fixed"))
    (dotimes (_ 5)
      (funcall deriver)
      (should (equal (with-current-buffer dst (buffer-string)) "fixed")))
    (derivation-test--kill-buffers (list bufs))))


(ert-deftest derivation--source-is-set ()
  "Target buffer gets derivation--source set by derivation-make-deriver."
  (let* ((bufs (derivation-test--with-buffers "hello"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver #'upcase src dst)))
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
         (deriver (derivation-make-deriver #'upcase src dst)))
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
         (deriver (derivation-make-deriver #'upcase src dst)))
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
         (deriver (derivation-make-deriver #'upcase src dst)))
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

;;; Error handling tests

(ert-deftest derivation-failure-keeps-last-good ()
  "When a command fails, the target keeps its last good render."
  (skip-unless (executable-find "sh"))
  (let* ((bufs (derivation-test--with-buffers "good"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver
                   "sh" src dst "-c"
                   "if grep -q '^bad' /dev/stdin; then echo errmsg >&2; exit 1; else cat; fi")))
    ;; First run: source is "good", command succeeds, target gets "good".
    (funcall deriver)
    (with-current-buffer dst
      (should (equal (buffer-string) "good"))
      (should-not derivation--error))
    ;; Change source to trigger failure.
    (with-current-buffer src (erase-buffer) (insert "bad content"))
    (funcall deriver)
    (with-current-buffer dst
      (should (equal (buffer-string) "good"))
      (should derivation--error)
      (should (string-match "errmsg" derivation--error)))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-failure-recovers ()
  "After a failure, fixing the source restores the derivation."
  (skip-unless (executable-find "sh"))
  (let* ((bufs (derivation-test--with-buffers "good"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver
                   "sh" src dst "-c"
                   "if grep -q '^bad' /dev/stdin; then echo err >&2; exit 1; else cat; fi")))
    (funcall deriver)
    (should (equal (with-current-buffer dst (buffer-string)) "good"))
    (should-not (with-current-buffer dst derivation--error))
    ;; Make it fail.
    (with-current-buffer src (erase-buffer) (insert "bad content"))
    (funcall deriver)
    (should (with-current-buffer dst derivation--error))
    (should (equal (with-current-buffer dst (buffer-string)) "good"))
    ;; Fix it.
    (with-current-buffer src (erase-buffer) (insert "good again"))
    (funcall deriver)
    (should (equal (with-current-buffer dst (buffer-string)) "good again"))
    (should-not (with-current-buffer dst derivation--error))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-function-error-keeps-last-good ()
  "When the Elisp function signals, the last good output is preserved."
  (let* ((bufs (derivation-test--with-buffers "hello"))
         (src (car bufs))
         (dst (cdr bufs))
         (ok-then-fail
          (let ((called nil))
            (lambda (c)
              (if called
                  (error "function failed")
                (setq called t)
                (upcase c)))))
         (deriver (derivation-make-deriver ok-then-fail src dst)))
    ;; First call: tick != -1, function succeeds → target gets "HELLO".
    (funcall deriver)
    (should (equal (with-current-buffer dst (buffer-string)) "HELLO"))
    (should-not (with-current-buffer dst derivation--error))
    ;; Second call: modify source to bump tick, then function errors.
    (with-current-buffer src (erase-buffer) (insert "hello"))
    (funcall deriver)
    (with-current-buffer dst
      (should (equal (buffer-string) "HELLO"))
      (should derivation--error)
      (should (string-match "function failed" derivation--error)))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-run-hooks-isolates-errors ()
  "One broken deriver does not prevent others from running."
  (let* ((bufs2 (derivation-test--with-buffers "a"))
         (src2 (car bufs2))
         (dst2 (cdr bufs2))
         (counter 0)
         (good (derivation-make-deriver
                (lambda (c) (cl-incf counter) c) src2 dst2))
         (bad (lambda () (error "broken"))))
    (let ((derivation--storage (list good bad)))
      (derivation-run-hooks)
      (should (> counter 0)))
    (derivation-test--kill-buffers (list bufs2))))

;;; Non-ASCII tests

(ert-deftest derivation-non-ascii-roundtrip ()
  "Non-ASCII text round-trips through an external command correctly."
  (skip-unless (executable-find "cat"))
  (let* ((bufs (derivation-test--with-buffers "héllo wörld ★"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver "cat" src dst)))
    (funcall deriver)
    (with-current-buffer dst
      (should (equal (buffer-string) "héllo wörld ★")))
    (derivation-test--kill-buffers (list bufs))))

;;; GC survival tests

(ert-deftest derivation-memo-survives-gc ()
  "Memoization cache is not wiped by garbage collection."
  (skip-unless (executable-find "cat"))
  (let* ((bufs (derivation-test--with-buffers "v1"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver "cat" src dst)))
    (funcall deriver)
    (should (equal (with-current-buffer dst (buffer-string)) "v1"))
    ;; Tamper target.
    (with-current-buffer dst (erase-buffer) (insert "tampered"))
    ;; Force several GC cycles.
    (garbage-collect)
    (garbage-collect)
    (funcall deriver)
    ;; Memoization should still hold: tick hasn't changed, no overwrite.
    (should (equal (with-current-buffer dst (buffer-string)) "tampered"))
    (derivation-test--kill-buffers (list bufs))))

;;; Dead buffer tests

(ert-deftest derivation-dead-source-buffer ()
  "Deriver becomes a no-op when its source buffer is killed."
  (skip-unless (executable-find "cat"))
  (let* ((bufs (derivation-test--with-buffers "x"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver "cat" src dst)))
    (funcall deriver)
    (should (equal (with-current-buffer dst (buffer-string)) "x"))
    (kill-buffer src)
    ;; Should not signal — buffer-live-p check returns nil.
    (funcall deriver)
    (should (equal (with-current-buffer dst (buffer-string)) "x"))
    (kill-buffer dst)))

(ert-deftest derivation-dead-target-buffer ()
  "Deriver becomes a no-op when its target buffer is killed."
  (let* ((bufs (derivation-test--with-buffers "x"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver #'upcase src dst)))
    (funcall deriver)
    (should (equal (with-current-buffer dst (buffer-string)) "X"))
    (kill-buffer dst)
    (funcall deriver)
    (kill-buffer src)))

(ert-deftest derivation-dead-buffers-in-run-hooks ()
  "derivation-run-hooks handles dead source buffers gracefully."
  (skip-unless (executable-find "cat"))
  (let* ((bufs (derivation-test--with-buffers "x"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver "cat" src dst))
         (bufs2 (derivation-test--with-buffers "a"))
         (src2 (car bufs2))
         (dst2 (cdr bufs2))
         (counter 0)
         (always-works
          (derivation-make-deriver
           (lambda (c) (cl-incf counter) c) src2 dst2)))
    (kill-buffer src)
    (kill-buffer dst)
    (let ((derivation--storage (list deriver always-works)))
      (derivation-run-hooks)
      (should (> counter 0)))
    (derivation-test--kill-buffers (list bufs2))))

;;; Section filter tests

(ert-deftest derivation-section-filter ()
  "derivation-make-section-filter copies matching section text.
Without magit loaded, falls back to copying the whole buffer."
  (let* ((bufs (derivation-test--with-buffers "line1\nline2\nline3"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-section-filter
                   (lambda (_) t) src dst)))
    (funcall deriver)
    (with-current-buffer dst
      (should (equal (buffer-string) "line1\nline2\nline3"))
      (should derivation--source))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-section-filter-memoized ()
  "Section filter is memoized on source buffer tick."
  (let* ((bufs (derivation-test--with-buffers "initial"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-section-filter
                   (lambda (_) t) src dst)))
    (funcall deriver)
    (should (equal (with-current-buffer dst (buffer-string)) "initial"))
    (with-current-buffer dst (erase-buffer) (insert "tampered"))
    (funcall deriver)
    (should (equal (with-current-buffer dst (buffer-string)) "tampered"))
    (with-current-buffer src (erase-buffer) (insert "changed"))
    (funcall deriver)
    (should (equal (with-current-buffer dst (buffer-string)) "changed"))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation--walk-tree-skips-root-when-asked ()
  "`derivation--walk-tree' with SKIP-ROOT non-nil skips the root node.

Regression test for the section-filter fix: a predicate matching the
root must not duplicate the whole buffer text."
  (cl-defstruct (derivation-test--node (:constructor derivation-test--mknode
                                                     (start end children)))
    start end children)
  (cl-defmethod derivation--node-children ((node derivation-test--node))
    (derivation-test--node-children node))
  (let* ((leaf (derivation-test--mknode 7 9 nil))
         (mid (derivation-test--mknode 6 20 (list leaf)))
         (root (derivation-test--mknode 1 100 (list mid))))
    (should (equal (mapcar #'derivation-test--node-start
                           (derivation--walk-tree root (lambda (_) t) t))
                   '(6 7)))
    (should (equal (mapcar #'derivation-test--node-start
                           (derivation--walk-tree root (lambda (_) t)))
                   '(1 6 7)))))

;;; Variable derivation tests

(defvar derivation-test--foo)
(defvar derivation-test--baz)

(ert-deftest derivation-var-basic ()
  "Variable derivation: `baz' derives from `foo' via `length'."
  (let ((derivation-test--foo (list 1 2 3))
        derivation-test--baz)
    (let ((deriver (derivation-make-var-deriver #'length 'derivation-test--foo
                                     'derivation-test--baz)))
      (funcall deriver)
      (should (equal derivation-test--baz
                     (length derivation-test--foo))))))

(ert-deftest derivation-var-memoization ()
  "Variable derivation is memoized when source hasn't changed."
  (let ((derivation-test--foo (list 1 2 3))
        derivation-test--baz)
    (let ((deriver (derivation-make-var-deriver #'length 'derivation-test--foo
                                     'derivation-test--baz)))
      (funcall deriver)
      (should (equal derivation-test--baz 3))
      (setq derivation-test--baz 99)
      (funcall deriver)
      (should (equal derivation-test--baz 99)))))

(ert-deftest derivation-var-source-change ()
  "Variable derivation recomputes when source variable changes."
  (let ((derivation-test--foo (list 1 2 3))
        derivation-test--baz)
    (let ((deriver (derivation-make-var-deriver #'length 'derivation-test--foo
                                     'derivation-test--baz)))
      (funcall deriver)
      (should (equal derivation-test--baz 3))
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
    (let ((deriver (derivation-make-var-deriver #'length 'derivation-test--foo
                                     'derivation-test--baz)))
      (funcall deriver)
      (should (equal derivation-test--baz 3))
      (setcar derivation-test--foo 42)
      (funcall deriver)
      (should (equal derivation-test--baz 3))
      (setcdr (last derivation-test--foo) '(4))
      (funcall deriver)
      (should (equal derivation-test--baz 4)))))

(ert-deftest derivation-var-multiple-calls ()
  "Repeated calls without source change don't re-derive."
  (let ((derivation-test--foo (list 1 2 3))
        derivation-test--baz)
    (let ((deriver (derivation-make-var-deriver #'length 'derivation-test--foo
                                     'derivation-test--baz)))
      (funcall deriver)
      (dotimes (_ 10)
        (funcall deriver)
        (should (equal derivation-test--baz 3))))))

(provide 'derivation-tests)
;;; derivation-tests.el ends here
