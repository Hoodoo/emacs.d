;;; hoodoo-session-context-test.el --- Tests for hoodoo-session-context -*- lexical-binding: t; -*-
;;; Code:

(require 'ert)

(ert-deftest hoodoo/session-test-default-label ()
  (should (equal (hoodoo/session--default-label "/home/hoooo/proj/") "proj"))
  (should (equal (hoodoo/session--default-label "/home/hoooo/proj") "proj"))
  (should (equal (hoodoo/session--default-label "/home/hoooo/") "hoooo")))

(provide 'hoodoo-session-context-test)
;;; hoodoo-session-context-test.el ends here
