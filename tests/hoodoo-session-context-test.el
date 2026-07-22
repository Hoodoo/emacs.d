;;; hoodoo-session-context-test.el --- Tests for hoodoo-session-context -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)

(ert-deftest hoodoo/session-test-default-label ()
  (should (equal (hoodoo/session--default-label "/home/hoooo/proj/") "proj"))
  (should (equal (hoodoo/session--default-label "/home/hoooo/proj") "proj"))
  (should (equal (hoodoo/session--default-label "/home/hoooo/") "hoooo")))

(ert-deftest hoodoo/session-test-tag-and-lookup ()
  (let ((session (generate-new-buffer "session"))
        (eat-buf (generate-new-buffer "eat"))
        (dired-buf (generate-new-buffer "dired"))
        (unrelated (generate-new-buffer "unrelated")))
    (unwind-protect
        (progn
          (hoodoo/session--tag-buffer eat-buf session)
          (hoodoo/session--tag-buffer dired-buf session)
          (should (eq (buffer-local-value 'hoodoo/session-buffer eat-buf) session))
          (should (equal (sort (mapcar #'buffer-name
                                        (hoodoo/session--attached-buffers session))
                                #'string<)
                          (sort (list "dired" "eat") #'string<)))
          (should (null (hoodoo/session--attached-buffers unrelated))))
      (mapc #'kill-buffer (list session eat-buf dired-buf unrelated)))))

(ert-deftest hoodoo/session-test-attached-buffers-excludes-killed ()
  (let ((session (generate-new-buffer "session"))
        (eat-buf (generate-new-buffer "eat")))
    (unwind-protect
        (progn
          (hoodoo/session--tag-buffer eat-buf session)
          (kill-buffer eat-buf)
          (should (null (hoodoo/session--attached-buffers session))))
      (kill-buffer session))))

(provide 'hoodoo-session-context-test)
;;; hoodoo-session-context-test.el ends here
