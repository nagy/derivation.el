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

(defun derivation-test--run-until (predicate &optional timeout)
  "Run hooks and pump process output until PREDICATE or TIMEOUT."
  (let ((deadline (time-add (current-time) (or timeout 3))))
    (while (and (not (funcall predicate))
                (time-less-p (current-time) deadline))
      (derivation-run-hooks)
      (accept-process-output nil 0.05))
    (funcall predicate)))


;;; Buffer derivation tests

(ert-deftest derivation-identity ()
  "Source content passes through `cat' unchanged into target."
  (skip-unless (executable-find "cat"))
  (let* ((bufs (derivation-test--with-buffers "hello world"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver "cat" src dst)))
    (should (derivation-test--run-until
             (lambda () (equal (with-current-buffer dst (buffer-string))
                                "hello world"))))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-command-is-async ()
  "A string command starts in the background; the target updates later."
  (skip-unless (executable-find "sh"))
  (let* ((bufs (derivation-test--with-buffers "hello"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver "sh" src dst "-c" "sleep 0.2; cat")))
    (funcall deriver)
    ;; The call returned before the command produced output.
    (should (equal (with-current-buffer dst (buffer-string)) ""))
    (should (derivation-test--run-until
             (lambda () (equal (with-current-buffer dst (buffer-string)) "hello"))))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-command-discards-stale-output ()
  "Output produced for an older source tick is discarded."
  (skip-unless (executable-find "sh"))
  (let* ((bufs (derivation-test--with-buffers "old"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver "sh" src dst "-c" "sleep 0.2; cat")))
    (funcall deriver)
    (with-current-buffer src (erase-buffer) (insert "new"))
    (should (derivation-test--run-until
             (lambda () (equal (with-current-buffer dst (buffer-string)) "new"))))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-sink-preserves-point-and-markers ()
  "Re-deriving keeps point and markers in the target."
  (let* ((bufs (derivation-test--with-buffers "line1\nline2\nline3\n"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver #'identity src dst)))
    (funcall deriver)
    (with-current-buffer dst
      (set-buffer-modified-p nil)
      (goto-char 4)
      (let ((m (copy-marker 8)))
        ;; A minimal edit elsewhere in the source; point/marker untouched.
        (with-current-buffer src
          (goto-char (point-min))
          (search-forward "line3")
          (replace-match "LINE3"))
        (funcall deriver)
        (should (equal (buffer-string) "line1\nline2\nLINE3\n"))
        (should (= (point) 4))
        (should (= (marker-position m) 8))
        ;; The derivation is not a user edit.
        (should-not (buffer-modified-p))))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-sink-runs-after-change-functions ()
  "The target write is visible to `after-change-functions'."
  (let* ((bufs (derivation-test--with-buffers "a"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver #'identity src dst))
         (changes 0))
    (funcall deriver)
    (with-current-buffer dst
      (add-hook 'after-change-functions (lambda (&rest _) (setq changes (1+ changes)))
                nil t))
    (with-current-buffer src (erase-buffer) (insert "b"))
    (funcall deriver)
    (should (> changes 0))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-transformation ()
  "Source content is uppercased via `tr a-z A-Z' into target."
  (skip-unless (executable-find "tr"))
  (let* ((bufs (derivation-test--with-buffers "hello world"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver "tr" src dst "a-z" "A-Z")))
    (should (derivation-test--run-until
             (lambda () (equal (with-current-buffer dst (buffer-string))
                                "HELLO WORLD"))))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-memoization ()
  "Target is not recomputed when source hasn't changed."
  (skip-unless (executable-find "cat"))
  (let* ((bufs (derivation-test--with-buffers "v1"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver "cat" src dst)))
    (should (derivation-test--run-until
             (lambda () (equal (with-current-buffer dst (buffer-string)) "v1"))))
    (with-current-buffer dst
      (erase-buffer)
      (insert "tampered"))
    (funcall deriver)
    (with-current-buffer dst
      (should (equal (buffer-string) "tampered")))
    (with-current-buffer src
      (erase-buffer)
      (insert "v2"))
    (should (derivation-test--run-until
             (lambda () (equal (with-current-buffer dst (buffer-string)) "v2"))))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-command-args ()
  "Extra arguments to derivation-make-deriver are passed to the command."
  (skip-unless (executable-find "tr"))
  (let* ((bufs (derivation-test--with-buffers "abc"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver "tr" src dst "abc" "xyz")))
    (should (derivation-test--run-until
             (lambda () (equal (with-current-buffer dst (buffer-string)) "xyz"))))
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
    (should (derivation-test--run-until
             (lambda () (equal (with-current-buffer dst (buffer-string)) "fixed"))))
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

;;; Auto-revert integration tests

(ert-deftest derivation-buffer-stale-function ()
  "Target's `buffer-stale-function' tracks the source buffer tick."
  (let* ((bufs (derivation-test--with-buffers "hello"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver #'upcase src dst)))
    (funcall deriver)
    (with-current-buffer dst
      (should (functionp buffer-stale-function))
      ;; Fresh after a run.
      (should-not (funcall buffer-stale-function t))
      ;; Changing the *target* must not count as stale.
      (erase-buffer) (insert "tampered")
      (should-not (funcall buffer-stale-function t)))
    (with-current-buffer src (erase-buffer) (insert "world"))
    (with-current-buffer dst
      (should (funcall buffer-stale-function t)))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-async-stale-quiet-while-pending ()
  "Staleness stays quiet while a command for the current tick runs."
  (skip-unless (executable-find "sh"))
  (let* ((bufs (derivation-test--with-buffers "hello"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver "sh" src dst "-c" "sleep 0.3; cat")))
    (funcall deriver)
    (with-current-buffer dst
      (should-not (funcall buffer-stale-function t)))
    (should (derivation-test--run-until
             (lambda () (equal (with-current-buffer dst (buffer-string)) "hello"))))
    (with-current-buffer dst
      (should-not (funcall buffer-stale-function t)))
    (with-current-buffer src (erase-buffer) (insert "world"))
    (with-current-buffer dst
      (should (funcall buffer-stale-function t)))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-revert-buffer-function ()
  "`revert-buffer' re-derives the target, bypassing memoization."
  (let* ((bufs (derivation-test--with-buffers "hello"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver #'upcase src dst)))
    (funcall deriver)
    (with-current-buffer dst
      (should (functionp revert-buffer-function))
      (erase-buffer) (insert "tampered")
      ;; revert-buffer must not prompt in batch: pass noconfirm.
      (revert-buffer nil t)
      (should (equal (buffer-string) "HELLO")))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-auto-revert-drives-target ()
  "`auto-revert-mode' in the target re-derives when the source changes."
  (let* ((bufs (derivation-test--with-buffers "hello"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver #'upcase src dst)))
    (funcall deriver)
    (unwind-protect
        (progn
          (with-current-buffer dst
            (auto-revert-mode 1)
            (should auto-revert-mode)
            (should (equal (buffer-string) "HELLO")))
          (with-current-buffer src (erase-buffer) (insert "world"))
          ;; Drive the auto-revert handler directly; no timer in batch.
          (auto-revert-buffer dst)
          (with-current-buffer dst
            (should (equal (buffer-string) "WORLD"))))
      (with-current-buffer dst (auto-revert-mode -1)))
    (derivation-test--kill-buffers (list bufs))))

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

(ert-deftest derivation-mode-line-form-error ()
  "The :eval form shows the error face and message after a failure."
  (let* ((bufs (derivation-test--with-buffers "hello"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver
                   (lambda (_content) (error "boom")) src dst)))
    (funcall deriver)
    (with-current-buffer dst
      (should derivation--error)
      (let ((result (eval (cadr derivation-mode-line))))
        (should (stringp result))
        (should (string-match "⟳!" result))
        (should (eq (get-text-property 0 'face result) 'error))
        (should (string-match "boom" (get-text-property 0 'help-echo result)))))
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
    (should (derivation-test--run-until
             (lambda () (equal (with-current-buffer dst (buffer-string)) "good"))))
    (with-current-buffer dst
      (should-not derivation--error))
    ;; Change source to trigger failure.
    (with-current-buffer src (erase-buffer) (insert "bad content"))
    (funcall deriver)
    (should (derivation-test--run-until
             (lambda () (with-current-buffer dst derivation--error))))
    (with-current-buffer dst
      (should (equal (buffer-string) "good"))
      (should derivation--error)
      (should (string-match "errmsg" derivation--error)))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-failure-retries-same-source ()
  "A failed command is retried on later calls without a source edit."
  (let* ((bufs (derivation-test--with-buffers "x"))
         (src (car bufs))
         (dst (cdr bufs))
         (calls 0)
         (flaky (lambda (c)
                  (cl-incf calls)
                  (if (= calls 1) (error "first fails") (upcase c))))
         (deriver (derivation-make-deriver flaky src dst)))
    ;; First call fails; source tick must not be consumed.
    (funcall deriver)
    (should (= calls 1))
    (should (with-current-buffer dst derivation--error))
    ;; Second call retries even though the source is unchanged.
    (funcall deriver)
    (should (= calls 2))
    (should (equal (with-current-buffer dst (buffer-string)) "X"))
    (should-not (with-current-buffer dst derivation--error))
    ;; Third call is memoized (no extra work).
    (funcall deriver)
    (should (= calls 2))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-failure-does-not-spin-fixpoint ()
  "A failing deriver is attempted once per `derivation-run-hooks' call."
  (let* ((bufs (derivation-test--with-buffers "x"))
         (src (car bufs))
         (dst (cdr bufs))
         (calls 0)
         (always-fails (lambda (_c) (cl-incf calls) (error "nope")))
         (deriver (derivation-make-deriver always-fails src dst)))
    (unwind-protect
        (progn
          (derivation-run-hooks)
          ;; Must not be retried `derivation--max-passes' times in one call.
          (should (= calls 1)))
      (derivation-unregister deriver)
      (derivation-test--kill-buffers (list bufs)))))

(ert-deftest derivation-stderr-buffer-killed-on-unregister ()
  "A failed command's hidden stderr buffer dies on unregister."
  (let* ((bufs (derivation-test--with-buffers "x"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver
                   (lambda (_c) (error "boom")) src dst)))
    ;; No stderr buffer exists until a command fails.
    (funcall deriver)
    (let ((name (buffer-name
                 (car (seq-filter
                       (lambda (b) (string-match-p "derivation-err" (buffer-name b)))
                       (buffer-list))))))
      (should (get-buffer name))
      (derivation-unregister deriver)
      (should-not (get-buffer name)))
    (derivation-test--kill-buffers (list bufs))))

(ert-deftest derivation-stderr-buffer-lazy ()
  "The stderr buffer is not created until a command fails."
  (let* ((bufs (derivation-test--with-buffers "x"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver #'identity src dst)))
    (unwind-protect
        (progn
          (funcall deriver)
          (should-not (seq-find
                       (lambda (b) (string-match-p "derivation-err" (buffer-name b)))
                       (buffer-list))))
      (derivation-unregister deriver)
      (derivation-test--kill-buffers (list bufs)))))

(ert-deftest derivation-var-watcher-removed-on-unregister ()
  "Unregistering the last var deriver removes the variable watcher."
  ;; Use fresh uninterned symbols so other tests' watchers do not
  ;; inflate the refcount for this source.
  (let* ((sym (make-symbol "derivation-test-var"))
         (out (make-symbol "derivation-test-out")))
    (set sym '(1 2 3))
    (let ((deriver (derivation-make-var-deriver #'length sym out)))
      (should (gethash sym derivation--var-watch-table))
      (should (memq #'derivation--var-bump (get-variable-watchers sym)))
      (derivation-unregister deriver)
      (should-not (gethash sym derivation--var-watch-table))
      ;; The watcher itself must be gone, not just the table entry.
      (should-not (memq #'derivation--var-bump (get-variable-watchers sym))))))

(ert-deftest derivation-var-watcher-refcount ()
  "Two derivers on the same source keep the watcher until both go."
  (let* ((sym (make-symbol "derivation-test-var2"))
         (out (make-symbol "derivation-test-out2")))
    (set sym '(1 2 3))
    (let ((d1 (derivation-make-var-deriver #'length sym out))
          (d2 (derivation-make-var-deriver #'identity sym out)))
      (derivation-unregister d1)
      (should (gethash sym derivation--var-watch-table))
      (should (memq #'derivation--var-bump (get-variable-watchers sym)))
      (derivation-unregister d2)
      (should-not (gethash sym derivation--var-watch-table))
      (should-not (memq #'derivation--var-bump (get-variable-watchers sym))))))

(ert-deftest derivation-failure-recovers ()
  "After a failure, fixing the source restores the derivation."
  (skip-unless (executable-find "sh"))
  (let* ((bufs (derivation-test--with-buffers "good"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver
                   "sh" src dst "-c"
                   "if grep -q '^bad' /dev/stdin; then echo err >&2; exit 1; else cat; fi")))
    (should (derivation-test--run-until
             (lambda () (equal (with-current-buffer dst (buffer-string)) "good"))))
    (should-not (with-current-buffer dst derivation--error))
    ;; Make it fail.
    (with-current-buffer src (erase-buffer) (insert "bad content"))
    (funcall deriver)
    (should (derivation-test--run-until
             (lambda () (with-current-buffer dst derivation--error))))
    (should (equal (with-current-buffer dst (buffer-string)) "good"))
    ;; Fix it.
    (with-current-buffer src (erase-buffer) (insert "good again"))
    (should (derivation-test--run-until
             (lambda () (equal (with-current-buffer dst (buffer-string))
                                "good again"))))
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
    (let ((derivation--storage (list (cons good nil) (cons bad nil))))
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
    (should (derivation-test--run-until
             (lambda () (equal (with-current-buffer dst (buffer-string))
                                "héllo wörld ★"))))
    (derivation-test--kill-buffers (list bufs))))

;;; GC survival tests

(ert-deftest derivation-memo-survives-gc ()
  "Memoization cache is not wiped by garbage collection."
  (skip-unless (executable-find "cat"))
  (let* ((bufs (derivation-test--with-buffers "v1"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver "cat" src dst)))
    (should (derivation-test--run-until
             (lambda () (equal (with-current-buffer dst (buffer-string)) "v1"))))
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
    (should (derivation-test--run-until
             (lambda () (equal (with-current-buffer dst (buffer-string)) "x"))))
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
    (let ((derivation--storage (list (cons deriver nil)
                                     (cons always-works nil))))
      (derivation-run-hooks)
      (should (> counter 0)))
    (derivation-test--kill-buffers (list bufs2))))

;;; Lifecycle / register-unregister tests

(ert-deftest derivation-register-unregister ()
  "derivation-register / derivation-unregister add and remove records."
  (let ((deriver (lambda () t)))
    (derivation-register deriver)
    (should (assq deriver derivation--storage))
    (should (derivation-unregister deriver))
    (should-not (assq deriver derivation--storage))
    (should-not (derivation-unregister deriver))))

(ert-deftest derivation-auto-unregister-on-kill ()
  "Killing a source or target buffer removes the deriver record."
  (let* ((bufs (derivation-test--with-buffers "hello"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver #'upcase src dst)))
    (funcall deriver)
    (should (assq deriver derivation--storage))
    (kill-buffer src)
    (should-not (assq deriver derivation--storage))
    (kill-buffer dst)))

(ert-deftest derivation-auto-unregister-on-target-kill ()
  "Killing the target buffer also removes the deriver record."
  (let* ((bufs (derivation-test--with-buffers "hello"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver #'upcase src dst)))
    (funcall deriver)
    (kill-buffer dst)
    (should-not (assq deriver derivation--storage))
    (kill-buffer src)))

(ert-deftest derivation-var-deriver-self-registers ()
  "Variable derivers are automatically registered."
  (let ((derivation-test--foo '(1 2 3))
        derivation-test--baz)
    (let ((deriver
           (derivation-make-var-deriver #'length 'derivation-test--foo
                                        'derivation-test--baz)))
      (should (assq deriver derivation--storage))
      (derivation-unregister deriver))))

;;; Pipeline / fixpoint tests

(ert-deftest derivation-pipeline-converges-in-one-call ()
  "A pipeline converges in a single `derivation-run-hooks' call."
  (let* ((a (generate-new-buffer " *pipeline-a*"))
         (b (generate-new-buffer " *pipeline-b*"))
         (c (generate-new-buffer " *pipeline-c*"))
         (d1 (derivation-make-deriver #'upcase a b))
         (d2 (derivation-make-deriver #'downcase b c)))
    (with-current-buffer a (insert "HeLLo"))
    (unwind-protect
        (progn
          (derivation-run-hooks)
          (should (equal (with-current-buffer c (buffer-string)) "hello")))
      (derivation-unregister d1)
      (derivation-unregister d2)
      (kill-buffer a) (kill-buffer b) (kill-buffer c))))

;;; Rerun chain tests

(ert-deftest derivation-rerun-runs-whole-chain ()
  "derivation-rerun re-runs the full upstream chain, not just the last."
  (let* ((a (generate-new-buffer " *rerun-a*"))
         (b (generate-new-buffer " *rerun-b*"))
         (c (generate-new-buffer " *rerun-c*"))
         (d1 (derivation-make-deriver #'upcase a b))
         (d2 (derivation-make-deriver #'downcase b c)))
    (with-current-buffer a (insert "xYz"))
    (unwind-protect
        (progn
          (derivation-run-hooks)
          (with-current-buffer c (erase-buffer) (insert "tampered"))
          (with-current-buffer c (derivation-rerun))
          (should (equal (with-current-buffer c (buffer-string)) "xyz")))
      (derivation-unregister d1)
      (derivation-unregister d2)
      (kill-buffer a) (kill-buffer b) (kill-buffer c))))

(ert-deftest derivation-rerun-refreshes-stale-intermediate ()
  "Rerun must refresh a stale intermediate before the downstream target.

Regression test for the `reverse' bug: rerunning at C re-ran the
C-transform (reading stale B) before the B-transform.  Tampering BOTH
B and C exposes it; the old test tampered only C and could not."
  (let* ((a (generate-new-buffer " *rerun-a*"))
         (b (generate-new-buffer " *rerun-b*"))
         (c (generate-new-buffer " *rerun-c*"))
         (d1 (derivation-make-deriver #'upcase   a b))
         (d2 (derivation-make-deriver #'downcase b c)))
    (with-current-buffer a (insert "hello"))
    (unwind-protect
        (progn
          (derivation-run-hooks)
          ;; Tamper the intermediate AND the target.
          (with-current-buffer b (erase-buffer) (insert "TAMPERED"))
          (with-current-buffer c (erase-buffer) (insert "TAMPERED"))
          (with-current-buffer c (derivation-rerun))
          (should (equal (with-current-buffer b (buffer-string)) "HELLO"))
          (should (equal (with-current-buffer c (buffer-string)) "hello")))
      (derivation-unregister d1)
      (derivation-unregister d2)
      (kill-buffer a) (kill-buffer b) (kill-buffer c))))

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
  (require 'eieio)
  (cl-defstruct (derivation-test--node (:constructor derivation-test--mknode
                                                     (start end children)))
    start end children)
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

(ert-deftest derivation-var-let-rebind-equal-no-recompute ()
  "A `let' rebinding to an `equal' value does not recompute."
  (let ((derivation-test--foo (list 1 2 3))
        (calls 0)
        derivation-test--baz)
    (let ((deriver (derivation-make-var-deriver
                    (lambda (v) (cl-incf calls) (length v))
                    'derivation-test--foo 'derivation-test--baz)))
      (funcall deriver)
      (should (= calls 1))
      ;; `let'-binding the source to an `equal' value fires the watcher
      ;; (generation bump) but must not rerun.
      (let ((derivation-test--foo (list 1 2 3)))
        (funcall deriver))
      (should (= calls 1))
      ;; A real change still recomputes.
      (setq derivation-test--foo (list 1 2 3 4))
      (funcall deriver)
      (should (= calls 2)))))

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

;;; Generic data derivation tests

(ert-deftest derivation-make-pushes-on-change-only ()
  "The memoized deriver pushes only when the data changed."
  (let ((data 1) (pushed nil))
    (let ((deriver (derivation-make
                    (lambda () data)
                    (lambda (d) (push d pushed)))))
      (should (funcall deriver))
      (should (equal pushed '(1)))
      (should-not (funcall deriver))            ; unchanged: no push
      (should (equal pushed '(1)))
      (setq data 2)
      (should (funcall deriver))
      (should (equal pushed '(2 1))))))

(ert-deftest derivation-make-not-auto-registered ()
  "derivation-make returns a plain function; registration is explicit."
  (let ((before (length derivation--storage)))
    (derivation-make (lambda () 1) (lambda (_d) nil))
    (should (= (length derivation--storage) before))))

(ert-deftest derivation-make-stamp-skips-pull ()
  "With STAMP-FN the pull is skipped while the stamp is unchanged."
  (let ((pulls 0) (stamp 1) (pushed nil))
    (let ((deriver (derivation-make
                    (lambda () (prog1 (list 'data stamp)
                                 (setq pulls (1+ pulls))))
                    (lambda (d) (push d pushed))
                    (lambda () stamp))))
      (should (funcall deriver))
      (should (= pulls 1))
      (should-not (funcall deriver))            ; stamp unchanged: no pull
      (should (= pulls 1))
      (setq stamp 2)
      (should (funcall deriver))
      (should (= pulls 2))
      (should (equal pushed '((data 2) (data 1)))))))

;;; Tabulated list derivation tests

(defun derivation-test--tab-entries ()
  "Test helper: one tabulated entry."
  '((a ["A" "1"])))

(ert-deftest derivation-tabulated-basic ()
  "Creates a populated tabulated-list buffer and registers a deriver."
  (let* ((before (length derivation--storage))
         (buf (derivation-make-tabulated
               (lambda () '((a ["A" "1"]) (b ["B" "2"])))
               [("Name" 20 t) ("PID" 8 t)]
               :name " *deriv-test-tab*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (should (derived-mode-p 'tabulated-list-mode))
            (should (equal tabulated-list-entries
                           '((a ["A" "1"]) (b ["B" "2"]))))
            (should (= (count-lines (point-min) (point-max)) 2))
            (should (string-match-p "^A" (buffer-string))))
          (should (= (length derivation--storage) (1+ before))))
      (kill-buffer buf))
    (should (= (length derivation--storage) before))))

(ert-deftest derivation-tabulated-updates-on-change ()
  "A changed entries list re-renders; unchanged data does not."
  (let ((state '((a ["A" "1"]))))
    (let ((buf (derivation-make-tabulated
                (lambda () state)
                [("Name" 20 t)]
                :name " *deriv-test-tab*")))
      (unwind-protect
          (progn
            (with-current-buffer buf
              (should (= (count-lines (point-min) (point-max)) 1)))
            (derivation-run-hooks)
            (with-current-buffer buf
              (should (= (count-lines (point-min) (point-max)) 1)))
            (setq state '((a ["A" "1"]) (b ["B" "2"])))
            (derivation-run-hooks)
            (with-current-buffer buf
              (should (= (count-lines (point-min) (point-max)) 2))))
        (kill-buffer buf)))))

(ert-deftest derivation-tabulated-unique-names ()
  "Each call makes a fresh buffer; taken names are uniquified."
  (let* ((b1 (derivation-make-tabulated (lambda () nil) [("Name" 20 t)]
                                        :name " *deriv-test-tab*"))
         (b2 (derivation-make-tabulated (lambda () nil) [("Name" 20 t)]
                                        :name " *deriv-test-tab*")))
    (unwind-protect
        (progn
          (should-not (eq b1 b2))
          (should (equal (buffer-name b1) " *deriv-test-tab*"))
          (should-not (equal (buffer-name b2) (buffer-name b1))))
      (kill-buffer b1)
      (kill-buffer b2)))
  ;; Visible names get the familiar <2> suffix (what the shells demo
  ;; relies on); space-prefixed names get a random suffix instead.
  (let* ((b1 (derivation-make-tabulated (lambda () nil) [("Name" 20 t)]
                                        :name "deriv-test-tab"))
         (b2 (derivation-make-tabulated (lambda () nil) [("Name" 20 t)]
                                        :name "deriv-test-tab")))
    (unwind-protect
        (should (equal (buffer-name b2) "deriv-test-tab<2>"))
      (kill-buffer b1)
      (kill-buffer b2))))

(ert-deftest derivation-tabulated-error-keeps-last-good ()
  "A failing entries function keeps the last table and sets the error."
  (let ((fail nil))
    (let ((buf (derivation-make-tabulated
                (lambda () (if fail (error "boom") '((a ["A" "1"]))))
                [("Name" 20 t)]
                :name " *deriv-test-tab*")))
      (unwind-protect
          (progn
            (with-current-buffer buf
              (should-not derivation--error)
              (should (string-match-p "^A" (buffer-string))))
            (setq fail t)
            (derivation-run-hooks)
            (with-current-buffer buf
              (should derivation--error)
              (should (string-match-p "^A" (buffer-string))))
            (setq fail nil)
            (derivation-run-hooks)
            (with-current-buffer buf
              (should-not derivation--error)))
        (kill-buffer buf)))))

(ert-deftest derivation-tabulated-mode-line-label ()
  "The mode-line shows the entries function name as the source."
  (let ((buf (derivation-make-tabulated
              #'derivation-test--tab-entries
              [("Name" 20 t)]
              :name " *deriv-test-tab*")))
    (unwind-protect
        (with-current-buffer buf
          (should (equal (car derivation--source)
                         "derivation-test--tab-entries"))
          (should (string-match-p
                   "derivation-test--tab-entries"
                   (get-text-property 0 'help-echo
                                      (eval (cadr derivation-mode-line))))))
      (kill-buffer buf))))

(ert-deftest derivation-tabulated-sort-key ()
  "The SORT-KEY argument sets `tabulated-list-sort-key'."
  (let ((buf (derivation-make-tabulated
              (lambda () '((a ["A" "1"])))
              [("Name" 20 t) ("PID" 8 t)]
              :name " *deriv-test-tab*"
              :sort-key '("PID" . nil))))
    (unwind-protect
        (with-current-buffer buf
          (should (equal tabulated-list-sort-key '("PID" . nil))))
      (kill-buffer buf))))

(ert-deftest derivation-tabulated-rerun ()
  "`derivation-rerun' works on a tabulated target (string-named source)."
  (let ((state '((a ["A" "1"]))))
    (let ((buf (derivation-make-tabulated
                (lambda () state)
                [("Name" 20 t)]
                :name " *deriv-test-tab*")))
      (unwind-protect
          (progn
            (with-current-buffer buf
              (should (equal tabulated-list-entries '((a ["A" "1"]))))
              (setq state '((a ["A" "1"]) (b ["B" "2"])))
              (derivation-rerun)
              (should (equal tabulated-list-entries
                             '((a ["A" "1"]) (b ["B" "2"]))))))
        (kill-buffer buf)))))

(ert-deftest derivation-buffer-names-as-sources ()
  "Constructors accept buffer names, not just buffer objects."
  (let* ((bufs (derivation-test--with-buffers "hello"))
         (src (car bufs))
         (dst (cdr bufs))
         (deriver (derivation-make-deriver
                   #'upcase (buffer-name src) (buffer-name dst))))
    (funcall deriver)
    (should (equal (with-current-buffer dst (buffer-string)) "HELLO"))
    (derivation-test--kill-buffers (list bufs))))
;;; Input and stamp tests

(defun derivation-test--git (dir &rest args)
  "Run git with ARGS in DIR, return exit status."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (apply #'call-process "git" nil t nil args))))

(ert-deftest derivation-buffer-input ()
  "A buffer input tracks text and its modification tick."
  (with-temp-buffer
    (insert "one")
    (let ((input (derivation-make-buffer-input (current-buffer) "test-buffer")))
      (should (equal (derivation-input-name input) "test-buffer"))
      (should (equal (derivation-input-value input) "one"))
      (goto-char (point-max))
      (insert "-two")
      (should (equal (derivation-input-value input) "one-two")))))

(ert-deftest derivation-input-pulls-once-until-invalidated ()
  "Without a stamp, an input pulls once and then on invalidation."
  (let ((pulls 0) (value 1))
    (let ((input (derivation-make-input (lambda () (cl-incf pulls) value))))
      (should (= (derivation-input-value input) 1))
      (should (= (derivation-input-value input) 1))
      (should (= pulls 1))
      (setq value 2)
      (should (= (derivation-input-value input) 1))
      (derivation-input-invalidate input)
      (should (= (derivation-input-value input) 2))
      (should (= pulls 2)))))

(ert-deftest derivation-input-stamp-skips-pull ()
  "An unchanged stamp avoids the pull; a changed stamp forces it."
  (let ((stamp 1) (pulls 0))
    (let ((input (derivation-make-input
                  (lambda () (cl-incf pulls) stamp)
                  (lambda () stamp))))
      (should (= (derivation-input-value input) 1))
      (should (= (derivation-input-value input) 1))
      (should (= pulls 1))
      (should-not (derivation-input-dirty-p input))
      (setq stamp 2)
      (should (derivation-input-dirty-p input))
      (should (= (derivation-input-value input) 2))
      (should (= pulls 2)))))

(ert-deftest derivation-input-failure-keeps-last-good ()
  "A failed pull keeps the cached value and retries on the next read."
  (let ((fail nil))
    (let ((input (derivation-make-input
                  (lambda ()
                    (if fail
                        (signal 'derivation--failed (list "boom"))
                      42)))))
      (should (= (derivation-input-value input) 42))
      (setq fail t)
      (derivation-input-invalidate input)
      (should-error (derivation-input-value input) :type 'derivation--failed)
      (should (equal (derivation-input-error input) "boom"))
      (setq fail nil)
      (should (= (derivation-input-value input) 42))
      (should-not (derivation-input-error input)))))

(ert-deftest derivation-stamp-always-changes ()
  "The polling stamp differs on every call."
  (let ((stamp (derivation-stamp-always)))
    (should-not (equal (funcall stamp) (funcall stamp)))))

(ert-deftest derivation-stamp-or-combines ()
  "The combined stamp changes when any component changes."
  (let* ((a 1) (b 1)
         (stamp (derivation-stamp-or (lambda () a) (lambda () b)))
         (before (funcall stamp)))
    (should (equal before (funcall stamp)))
    (setq b 2)
    (should-not (equal before (funcall stamp)))))

(ert-deftest derivation-stamp-mtime-tracks-file ()
  "The mtime stamp changes after a file update."
  (let* ((file (make-temp-file "deriv-stamp-"))
         (stamp (derivation-stamp-mtime file)))
    (unwind-protect
        (let ((before (funcall stamp)))
          (should (equal before (funcall stamp)))
          (set-file-times file (time-add (current-time) 10))
          (should-not (equal before (funcall stamp))))
      (delete-file file))))

(ert-deftest derivation-stamp-mtime-missing-file ()
  "A missing file stamps as nil."
  (should-not (funcall (derivation-stamp-mtime
                        (expand-file-name "deriv-does-not-exist"
                                          temporary-file-directory)))))

(ert-deftest derivation-stamp-git-tracks-head-and-worktree ()
  "The git stamp changes on commit and on tracked modifications."
  (skip-unless (executable-find "git"))
  (let ((dir (make-temp-file "deriv-git-" t)))
    (unwind-protect
        (progn
          (should (zerop (derivation-test--git dir "init" "-q")))
          (should (zerop (derivation-test--git dir "config" "user.email"
                                               "test@example.com")))
          (should (zerop (derivation-test--git dir "config" "user.name"
                                               "Test")))
          (with-temp-file (expand-file-name "a.txt" dir) (insert "one"))
          (should (zerop (derivation-test--git dir "add" "a.txt")))
          (should (zerop (derivation-test--git dir "commit" "-q" "-m" "one")))
          (let* ((stamp (derivation-stamp-git dir))
                 (before (funcall stamp)))
            (should (equal before (funcall stamp)))
            (with-temp-file (expand-file-name "a.txt" dir) (insert "two"))
            (should-not (equal before (funcall stamp)))))
      (delete-directory dir t))))

(ert-deftest derivation-command-input ()
  "A command input captures and trims stdout."
  (skip-unless (executable-find "sh"))
  (let ((input (derivation-make-command-input
                '("sh" "-c" "printf 'hello\\n'"))))
    (should (equal (derivation-input-wait input) "hello"))))

(ert-deftest derivation-command-input-async ()
  "The first read signals pending; wait returns the value."
  (skip-unless (executable-find "sh"))
  (let ((input (derivation-make-command-input
                '("sh" "-c" "sleep 0.2; printf hi"))))
    (should-error (derivation-input-value input) :type 'derivation--pending)
    (should (equal (derivation-input-wait input 3) "hi"))))

(ert-deftest derivation-async-retry-cooldown ()
  "A failed command waits before starting another job."
  (skip-unless (executable-find "sh"))
  (let* ((dir (file-name-as-directory (make-temp-file "deriv-retry-" t)))
         (counter (expand-file-name "count" dir))
         (bufs (derivation-test--with-buffers "x"))
         (src (car bufs))
         (dst (cdr bufs))
         (derivation--retry-delay 0.3)
         (deriver (derivation-make-deriver
                   "sh" src dst "-c"
                   (format "printf x >> %s; exit 1" counter))))
    (unwind-protect
        (progn
          (should (derivation-test--run-until
                   (lambda () (with-current-buffer dst derivation--error))))
          (should (= (file-attribute-size (file-attributes counter)) 1))
          ;; Inside the cooldown no new job starts and staleness is quiet.
          (derivation-run-hooks)
          (accept-process-output nil 0.05)
          (should (= (file-attribute-size (file-attributes counter)) 1))
          (with-current-buffer dst
            (should-not (funcall buffer-stale-function t)))
          ;; After the cooldown the command runs again.
          (sleep-for 0.5)
          (with-current-buffer dst
            (should (funcall buffer-stale-function t)))
          (derivation-run-hooks)
          (should (derivation-test--run-until
                   (lambda ()
                     (= (file-attribute-size (file-attributes counter)) 2)))))
      (derivation-unregister deriver)
      (derivation-test--kill-buffers (list bufs))
      (delete-directory dir t))))

(ert-deftest derivation-command-input-retry-cooldown ()
  "A failed command input waits before starting another job."
  (skip-unless (executable-find "sh"))
  (let* ((dir (file-name-as-directory (make-temp-file "deriv-retry-in-" t)))
         (counter (expand-file-name "count" dir))
         (derivation--retry-delay 0.3)
         (input (derivation-make-command-input
                 (list "sh" "-c"
                       (format "printf x >> %s; exit 1" counter)))))
    (unwind-protect
        (progn
          (should-error (derivation-input-wait input) :type 'derivation--failed)
          (should (= (file-attribute-size (file-attributes counter)) 1))
          (should-error (derivation-input-value input) :type 'derivation--pending)
          (should (= (file-attribute-size (file-attributes counter)) 1))
          (sleep-for 0.5)
          (should-error (derivation-input-wait input) :type 'derivation--failed)
          (should (= (file-attribute-size (file-attributes counter)) 2)))
      (delete-directory dir t))))

(ert-deftest derivation-command-input-directory ()
  "A command input runs in its DIRECTORY."
  (skip-unless (executable-find "sh"))
  (let* ((dir (file-name-as-directory (make-temp-file "deriv-dir-" t)))
         (input (derivation-make-command-input
                 '("sh" "-c" "pwd") :directory dir)))
    (unwind-protect
        (should (equal (file-truename (derivation-input-wait input))
                       (directory-file-name (file-truename dir))))
      (delete-directory dir t))))

(ert-deftest derivation-command-input-environment ()
  "A command input sees the appended environment."
  (skip-unless (executable-find "sh"))
  (let ((input (derivation-make-command-input
                '("sh" "-c" "printf %s \"$DERIV_TEST_VAR\"")
                :environment '("DERIV_TEST_VAR=abc"))))
    (should (equal (derivation-input-wait input) "abc"))))

(ert-deftest derivation-command-input-failure ()
  "A command input reports stderr and signals `derivation--failed'."
  (skip-unless (executable-find "sh"))
  (let ((input (derivation-make-command-input
                '("sh" "-c" "echo boom >&2; exit 3"))))
    (should-error (derivation-input-wait input) :type 'derivation--failed)
    (should (equal (derivation-input-error input) "boom"))))

(ert-deftest derivation-command-input-reactive-to-stamp ()
  "An mtime stamp reruns the command only after the file changes."
  (skip-unless (executable-find "sh"))
  (let* ((file (make-temp-file "deriv-in-"))
         (input (derivation-make-command-input
                 (list "sh" "-c" "cat \"$1\"" "sh" file)
                 :stamp (derivation-stamp-mtime file))))
    (unwind-protect
        (progn
          (with-temp-file file (insert "one"))
          (set-file-times file (time-add (current-time) 1))
          (should (equal (derivation-input-wait input) "one"))
          (with-temp-file file (insert "two"))
          (set-file-times file (time-add (current-time) 20))
          (should (equal (derivation-input-wait input) "two")))
      (delete-file file))))

;;; Process derivation tests

(defun derivation-test--wait-for (predicate &optional timeout)
  "Pump process output until PREDICATE returns non-nil or TIMEOUT."
  (let ((deadline (time-add (current-time) (or timeout 3))))
    (while (and (not (funcall predicate))
                (time-less-p (current-time) deadline))
      (accept-process-output nil 0.05))
    (funcall predicate)))

(defun derivation-test--process-cleanup (process)
  "Unregister PROCESS, wait for its child, then kill the log buffer."
  (ignore-errors (derivation-unregister process))
  (derivation-test--wait-for
   (lambda () (not (derivation-process-live-p process))) 5)
  (let ((log (derivation-process-log process)))
    (when (buffer-live-p log)
      (kill-buffer log))))

(defun derivation-test--file-contents (file)
  "Return FILE's contents, or nil when FILE does not exist."
  (when (file-exists-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (buffer-string))))

(ert-deftest derivation-process-basic ()
  "The constructor starts a child, registers a deriver and makes a log."
  (skip-unless (and (executable-find "sh") (executable-find "sleep")))
  (let ((before (length derivation--storage))
        (process nil))
    (unwind-protect
        (progn
          (setq process (derivation-make-process
                         :name "deriv-test-basic"
                         :command '("sh" "-c" "exec sleep 30")))
          (should (derivation-process-p process))
          (should (eq (derivation-process-status process) :running))
          (should (derivation-process-live-p process))
          (should (= (length derivation--storage) (1+ before)))
          (should (buffer-live-p (derivation-process-log process)))
          (with-current-buffer (derivation-process-log process)
            (should (equal (car derivation--source) "deriv-test-basic"))))
      (when process
        (derivation-test--process-cleanup process)))
    (should (= (length derivation--storage) before))))

(ert-deftest derivation-process-restarts-on-input-change ()
  "A changed input changes the resolved argv and restarts the child."
  (skip-unless (and (executable-find "sh") (executable-find "sleep")))
  (let* ((arg "one")
         (input (derivation-make-input (lambda () arg)))
         (process nil))
    (unwind-protect
        (progn
          (setq process (derivation-make-process
                         :name "deriv-test-input-change"
                         :command (list "sh" "-c" "exec sleep 30" "sh" input)))
          (let ((first (derivation-process-process process)))
            (should (process-live-p first))
            (should (equal (process-command first)
                           '("sh" "-c" "exec sleep 30" "sh" "one")))
            (setq arg "two")
            (derivation-input-invalidate input)
            (derivation-run-hooks)
            (should (derivation-test--wait-for
                     (lambda ()
                       (let ((second (derivation-process-process process)))
                         (and (not (eq first second))
                              (process-live-p second))))))
            (let ((second (derivation-process-process process)))
              (should (process-live-p second))
              (should-not (process-live-p first))
              (should (equal (process-command second)
                             '("sh" "-c" "exec sleep 30" "sh" "two"))))))
      (when process
        (derivation-test--process-cleanup process)))))

(ert-deftest derivation-process-restarts-on-program-change ()
  "Replacing the executable at the same path restarts the child."
  (skip-unless (and (executable-find "sh") (executable-find "sleep")))
  (let* ((dir (file-name-as-directory (make-temp-file "deriv-prog-" t)))
         (program (expand-file-name "server" dir))
         (process nil))
    (unwind-protect
        (progn
          (with-temp-file program
            (insert "#!/bin/sh\nexec sleep 30\n"))
          (set-file-modes program #o755)
          (setq process (derivation-make-process
                         :name "deriv-test-program"
                         :command (list program)))
          (let ((first (derivation-process-process process)))
            (should (process-live-p first))
            (derivation-run-hooks)
            (should (eq (derivation-process-process process) first))
            (with-temp-file program
              (insert "#!/bin/sh\n# changed\nexec sleep 30\n"))
            (set-file-modes program #o755)
            (set-file-times program (time-add (current-time) 10))
            (derivation-run-hooks)
            (should (derivation-test--wait-for
                     (lambda ()
                       (let ((second (derivation-process-process process)))
                         (and (not (eq first second))
                              (process-live-p second))))))
            (let ((second (derivation-process-process process)))
              (should (process-live-p second))
              (should-not (process-live-p first)))))
      (when process
        (derivation-test--process-cleanup process))
      (delete-directory dir t))))

(ert-deftest derivation-process-stop-and-start ()
  "Stop disables and kills the child; start re-enables it."
  (skip-unless (and (executable-find "sh") (executable-find "sleep")))
  (let ((process nil))
    (unwind-protect
        (progn
          (setq process (derivation-make-process
                         :name "deriv-test-stop-start"
                         :command '("sh" "-c" "exec sleep 30")))
          (derivation-process-stop process)
          (should (derivation-test--wait-for
                   (lambda () (eq (derivation-process-status process) :stopped))))
          (should-not (derivation-process-live-p process))
          (derivation-run-hooks)
          (should-not (derivation-process-live-p process))
          (derivation-process-start process)
          (should (derivation-process-live-p process))
          (should (eq (derivation-process-status process) :running)))
      (when process
        (derivation-test--process-cleanup process)))))

(ert-deftest derivation-process-stop-does-not-block ()
  "Stop returns before the child exits; SIGKILL follows the timeout."
  (skip-unless (and (executable-find "sh") (executable-find "sleep")))
  (let* ((dir (file-name-as-directory (make-temp-file "deriv-stop-" t)))
         (ready (expand-file-name "ready" dir))
         (process nil))
    (unwind-protect
        (progn
          (setq process
                (derivation-make-process
                 :name "deriv-test-stop-async"
                 :command (list "sh" "-c"
                                "trap '' TERM; : > \"$1\"; while :; do sleep 1; done"
                                "sh" ready)
                 :stop-timeout 0.3))
          (should (derivation-test--wait-for
                   (lambda () (file-exists-p ready))))
          (derivation-process-stop process)
          ;; The child ignores TERM, so it survives the non-blocking call.
          (should (derivation-process-live-p process))
          (should (eq (derivation-process-status process) :stopping))
          (should (derivation-test--wait-for
                   (lambda () (not (derivation-process-live-p process))) 3))
          (should (derivation-test--wait-for
                   (lambda () (eq (derivation-process-status process) :stopped)))))
      (when process
        (derivation-test--process-cleanup process))
      (delete-directory dir t))))

(ert-deftest derivation-process-unregister-stops ()
  "Unregistering the handle stops the child and drops the deriver."
  (skip-unless (and (executable-find "sh") (executable-find "sleep")))
  (let* ((process (derivation-make-process
                   :name "deriv-test-unregister"
                   :command '("sh" "-c" "exec sleep 30")))
         (deriver (derivation-process-deriver process)))
    (derivation-unregister process)
    (should (derivation-test--wait-for
             (lambda () (not (derivation-process-live-p process)))))
    (should-not (assq deriver derivation--storage))
    (derivation-test--process-cleanup process)))

(ert-deftest derivation-process-log-kill-stops ()
  "Killing the log buffer unregisters the deriver and stops the child."
  (skip-unless (and (executable-find "sh") (executable-find "sleep")))
  (let* ((process (derivation-make-process
                   :name "deriv-test-log-kill"
                   :command '("sh" "-c" "exec sleep 30")))
         (deriver (derivation-process-deriver process)))
    (kill-buffer (derivation-process-log process))
    (should (derivation-test--wait-for
             (lambda () (not (derivation-process-live-p process)))))
    (should-not (assq deriver derivation--storage))
    (derivation-test--process-cleanup process)))

(ert-deftest derivation-process-no-restart-on-crash ()
  "With auto-restart nil, an exited child stays dead and reports status."
  (skip-unless (executable-find "sh"))
  (let ((process nil))
    (unwind-protect
        (progn
          (setq process (derivation-make-process
                         :name "deriv-test-crash"
                         :command '("sh" "-c" "exit 3")
                         :auto-restart nil))
          (should (derivation-test--wait-for
                   (lambda ()
                     (eq (derivation-process-status process) :exited))))
          (should (equal (derivation-process-exit-status process) 3))
          (should (derivation-process-last-error process))
          (derivation-run-hooks)
          (should-not (derivation-process-live-p process)))
      (when process
        (derivation-test--process-cleanup process)))))

(ert-deftest derivation-process-restarts-on-crash ()
  "Auto-restart brings an unexpectedly killed child back."
  (skip-unless (and (executable-find "sh") (executable-find "sleep")))
  (let ((process nil))
    (unwind-protect
        (progn
          (setq process (derivation-make-process
                         :name "deriv-test-crash-restart"
                         :command '("sh" "-c" "exec sleep 30")
                         :backoff '(0.05)))
          (let ((first (derivation-process-process process)))
            (signal-process first 'SIGKILL)
            (should (derivation-test--wait-for
                     (lambda ()
                       (let ((current (derivation-process-process process)))
                         (and (not (eq first current))
                              (process-live-p current))))))
            (should (derivation-process-live-p process))
            (should (>= (derivation-process-restart-count process) 1))))
      (when process
        (derivation-test--process-cleanup process)))))

(ert-deftest derivation-process-debounce-defers-restart ()
  "A debounced spec change keeps the old child until the timer fires."
  (skip-unless (and (executable-find "sh") (executable-find "sleep")))
  (let* ((arg "one")
         (input (derivation-make-input (lambda () arg)))
         (process nil))
    (unwind-protect
        (progn
          (setq process (derivation-make-process
                         :name "deriv-test-debounce"
                         :command (list "sh" "-c" "exec sleep 30" "sh" input)
                         :debounce 5))
          (let ((first (derivation-process-process process)))
            (setq arg "two")
            (derivation-input-invalidate input)
            (derivation-run-hooks)
            (should (eq (derivation-process-process process) first))
            (should (process-live-p first))
            (should (derivation-process-pending-spec process))
            (derivation-process-stop process)
            (should-not (derivation-process-pending-spec process))
            (should-not (derivation-process-timer process))
            (should (derivation-test--wait-for
                     (lambda () (not (derivation-process-live-p process)))))
            (should-not (derivation-process-live-p process))))
      (when process
        (derivation-test--process-cleanup process)))))

(ert-deftest derivation-process-input-failure-keeps-running ()
  "A failing input keeps the old child running and records the error."
  (skip-unless (and (executable-find "sh") (executable-find "sleep")))
  (let* ((fail nil)
         (input (derivation-make-input
                 (lambda ()
                   (if fail
                       (signal 'derivation--failed (list "boom"))
                     "one"))))
         (process nil))
    (unwind-protect
        (progn
          (setq process (derivation-make-process
                         :name "deriv-test-input-failure"
                         :command (list "sh" "-c" "exec sleep 30" "sh" input)))
          (let ((first (derivation-process-process process)))
            (setq fail t)
            (derivation-input-invalidate input)
            (derivation-run-hooks)
            (should (eq (derivation-process-process process) first))
            (should (process-live-p first))
            (should (equal (derivation-process-last-error process) "boom"))
            (with-current-buffer (derivation-process-log process)
              (should (equal derivation--error "boom")))
            (setq fail nil)
            (derivation-input-invalidate input)
            (derivation-run-hooks)
            (should-not (derivation-process-last-error process))
            (with-current-buffer (derivation-process-log process)
              (should-not derivation--error))))
      (when process
        (derivation-test--process-cleanup process)))))

(ert-deftest derivation-process-directory-and-environment ()
  "Inputs resolve for the working directory and the environment."
  (skip-unless (and (executable-find "sh") (executable-find "sleep")))
  (let* ((dir (file-name-as-directory (make-temp-file "deriv-proc-dir-" t)))
         (out (expand-file-name "out" dir))
         (dir-input (derivation-make-input (lambda () dir)))
         (value-input (derivation-make-input (lambda () "hello")))
         (process nil))
    (unwind-protect
        (progn
          (setq process (derivation-make-process
                         :name "deriv-test-dir-env"
                         :command '("sh" "-c"
                                    "printf %s \"$DERIV_VAR\" > out; exec sleep 30")
                         :directory dir-input
                         :environment (list (cons "DERIV_VAR" value-input))))
          (should (derivation-test--wait-for
                   (lambda ()
                     (equal (derivation-test--file-contents out) "hello")))))
      (when process
        (derivation-test--process-cleanup process))
      (delete-directory dir t))))

(ert-deftest derivation-process-on-change-reloads ()
  "A nil :on-change result keeps the child and records the new spec."
  (skip-unless (and (executable-find "sh") (executable-find "sleep")))
  (let* ((arg "one")
         (input (derivation-make-input (lambda () arg)))
         (seen nil)
         (process nil))
    (unwind-protect
        (progn
          (setq process
                (derivation-make-process
                 :name "deriv-test-on-change"
                 :command (list "sh" "-c" "exec sleep 30" "sh" input)
                 :on-change (lambda (old new)
                              (push (list (plist-get old :command)
                                          (plist-get new :command))
                                    seen)
                              nil)))
          (let ((first (derivation-process-process process)))
            (setq arg "two")
            (derivation-input-invalidate input)
            (derivation-run-hooks)
            (should (eq (derivation-process-process process) first))
            (should (process-live-p first))
            (should (equal (car seen)
                           '(("sh" "-c" "exec sleep 30" "sh" "one")
                             ("sh" "-c" "exec sleep 30" "sh" "two"))))
            (should (equal (plist-get (derivation-process-spec process) :command)
                           '("sh" "-c" "exec sleep 30" "sh" "two")))
            (derivation-run-hooks)
            (should (= (length seen) 1))))
      (when process
        (derivation-test--process-cleanup process)))))

(ert-deftest derivation-process-on-change-restarts ()
  "A :restart :on-change result replaces the child."
  (skip-unless (and (executable-find "sh") (executable-find "sleep")))
  (let* ((arg "one")
         (input (derivation-make-input (lambda () arg)))
         (calls 0)
         (process nil))
    (unwind-protect
        (progn
          (setq process
                (derivation-make-process
                 :name "deriv-test-on-change-restart"
                 :command (list "sh" "-c" "exec sleep 30" "sh" input)
                 :on-change (lambda (_old _new) (cl-incf calls) :restart)))
          (let ((first (derivation-process-process process)))
            (setq arg "two")
            (derivation-input-invalidate input)
            (derivation-run-hooks)
            (should (= calls 1))
            (should (derivation-test--wait-for
                     (lambda ()
                       (let ((second (derivation-process-process process)))
                         (and (not (eq first second))
                              (process-live-p second))))))
            (should-not (process-live-p first))))
      (when process
        (derivation-test--process-cleanup process)))))

(ert-deftest derivation-process-on-change-invalid-result ()
  "A bad :on-change result keeps the child and records an error."
  (skip-unless (and (executable-find "sh") (executable-find "sleep")))
  (let* ((arg "one")
         (input (derivation-make-input (lambda () arg)))
         (process nil))
    (unwind-protect
        (progn
          (setq process
                (derivation-make-process
                 :name "deriv-test-on-change-bad"
                 :command (list "sh" "-c" "exec sleep 30" "sh" input)
                 :on-change (lambda (_old _new) :bogus)))
          (let ((first (derivation-process-process process))
                (old-command (plist-get (derivation-process-spec process)
                                        :command)))
            (setq arg "two")
            (derivation-input-invalidate input)
            (derivation-run-hooks)
            (should (eq (derivation-process-process process) first))
            (should (process-live-p first))
            (should (string-match-p "on-change"
                                    (derivation-process-last-error process)))
            (should (equal (plist-get (derivation-process-spec process) :command)
                           old-command))))
      (when process
        (derivation-test--process-cleanup process)))))

(ert-deftest derivation-process-on-change-after-debounce ()
  "The hook runs when the debounce timer fires, not before."
  (skip-unless (and (executable-find "sh") (executable-find "sleep")))
  (let* ((arg "one")
         (input (derivation-make-input (lambda () arg)))
         (calls 0)
         (process nil))
    (unwind-protect
        (progn
          (setq process
                (derivation-make-process
                 :name "deriv-test-on-change-debounce"
                 :command (list "sh" "-c" "exec sleep 30" "sh" input)
                 :debounce 0.05
                 :on-change (lambda (_old _new) (cl-incf calls) nil)))
          (let ((first (derivation-process-process process)))
            (setq arg "two")
            (derivation-input-invalidate input)
            (derivation-run-hooks)
            (should (= calls 0))
            (should (derivation-test--wait-for (lambda () (= calls 1)) 2))
            (should (eq (derivation-process-process process) first))
            (should (process-live-p first))))
      (when process
        (derivation-test--process-cleanup process)))))

(provide 'derivation-tests)
;;; derivation-tests.el ends here
