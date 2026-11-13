;;; early-init.el --- exomachina  -*- lexical-binding: t; -*-

;; Start bare.  The environment grows from here.
(setq inhibit-startup-screen t
      frame-inhibit-implied-resize t
      native-comp-async-report-warnings-errors 'silent)
(push '(menu-bar-lines . 0) default-frame-alist)
(push '(tool-bar-lines . 0) default-frame-alist)
(push '(vertical-scroll-bars) default-frame-alist)

;;; early-init.el ends here
