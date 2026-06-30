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

;; Package-Requires: ((emacs "30.1"))

;; NIX-EMACS-PACKAGE: memoize
(require 'memoize)

(defun memoize-by-buffer-contents--wrap-buf (func buf)
  "Adaptation from library `memoize.el'."
  (let ((memoization-table (make-hash-table :test 'equal :weakness 'key))
        (buffer-to-contents-table (make-hash-table :weakness 'key))
        (contents-to-memoization-table (make-hash-table :weakness 'key)))
    (lambda (&rest args)
      (let* ((buftick (cons buf (buffer-chars-modified-tick buf)))
             (memokey (cons buftick args))
             (value (gethash memokey memoization-table)))
        (or value
            (progn
              (puthash buf buftick buffer-to-contents-table)
              (puthash buftick memokey contents-to-memoization-table)
              (puthash memokey (apply func args) memoization-table)))))))

(defvar derivation--storage nil)
(defun make-deriver (command frombuf tobuf &rest rest)
  "Return a new symbol function with no arguments, that applies the changes
to the buffer.

The returned function is memoized, so you can call it often without it
impeding performance."
  (let ((outsym (gensym "derivation--tracker-"))
        (buf (if (bufferp frombuf)
                 frombuf
               (get-buffer frombuf))))
    (fset outsym
          (lambda ()
            (let ((it (with-current-buffer frombuf
                        (buffer-substring-no-properties (point-min) (point-max)))))
              (with-current-buffer tobuf
                (save-excursion
                  (atomic-change-group
                    (erase-buffer)
                    (insert (with-temp-buffer
                              (let* ((default-process-coding-system '(no-conversion . no-conversion))
                                     (exitcode (apply #'call-process-region
                                                     `(,it
                                                       nil
                                                       ,command nil
                                                       ,(list (current-buffer) t)
                                                       nil
                                                       ,@rest))))
                                (if (zerop exitcode)
                                    (string-trim (buffer-string))
                                  (buffer-string)))))))))
            t))
    (fset outsym (memoize-by-buffer-contents--wrap-buf (symbol-function outsym)
                                                       buf))
    outsym))

(defun run-hooks-derivation ()
  (interactive)
  (run-hooks 'derivation--storage))
;(run-with-idle-timer 0.1 t #'run-hooks-derivation)

;; (setq derivation--storage (list (make-deriver "yj"
;;                                               (get-buffer "foo.toml")
;;                                               (get-buffer-create "*baz*")
;;                                               "-tj" "-i")
;;                                 (make-deriver "yqMP"
;;                                               (get-buffer-create "*baz*")
;;                                               (get-buffer-create "*quux*"))
;;                                 (make-deriver "yj"
;;                                               (get-buffer-create "*quux*")
;;                                               (get-buffer-create "*zott*")
;;                                               "-yt" "-i")))

;; (setq derivation--storage
;;       (list (make-deriver "/tmp/t106/hello"
;;                           ;; (get-buffer-create "rose.webp")
;;                           (get-buffer-create "gopher.png")
;;                           (get-buffer-create "*f*"))
;;             (make-deriver "jq"
;;                           (get-buffer-create "*f*")
;;                           (get-buffer-create "*g*"))))

(provide 'derivation)
;;; derivation.el ends here
