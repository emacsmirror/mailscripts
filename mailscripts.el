;;; mailscripts.el --- functions to access tools in the mailscripts package

;; Author: Sean Whitton <spwhitton@spwhitton.name>
;; Version: 0.12
;; Package-Requires: (notmuch projectile)

;; Copyright (C) 2018, 2019 Sean Whitton

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Code:

(require 'notmuch)
(require 'projectile)

(defgroup mailscripts nil
  "Customisation of functions in the mailscripts package.")

(defcustom mailscripts-extract-patches-branch-prefix nil
  "Prefix for git branches created by functions which extract patch series.

E.g. `mailed/'."
  :type 'string
  :group 'mailscripts)

;;;###autoload
(defun notmuch-slurp-debbug (bug &optional no-open)
  "Slurp Debian bug with bug number BUG and open the thread in notmuch.

If NO-OPEN, don't open the thread."
  (interactive "sBug number: ")
  (call-process-shell-command (concat "notmuch-slurp-debbug " bug))
  (unless no-open
    (notmuch-show (concat "Bug#" bug))))

;;;###autoload
(defun notmuch-slurp-this-debbug ()
  "When viewing a Debian bug in notmuch, download any missing messages."
  (interactive)
  (let ((subject (notmuch-show-get-subject)))
    (when (string-match "Bug#\\([0-9]+\\):" subject)
      (notmuch-slurp-debbug (match-string 1 subject) t))
    (notmuch-refresh-this-buffer)))

;;;###autoload
(defun notmuch-extract-thread-patches (repo branch)
  "Extract patch series in current thread to branch BRANCH in repo REPO.

The target branch may or may not already exist.

See notmuch-extract-patch(1) manpage for limitations: in
particular, this Emacs Lisp function supports passing only entire
threads to the notmuch-extract-patch(1) command."
  (interactive "Dgit repo: \nsnew branch name: ")
  (let ((thread-id notmuch-show-thread-id)
        (default-directory (expand-file-name repo)))
    (mailscripts--check-out-branch branch)
    (shell-command
     (format "notmuch-extract-patch %s | git am"
             (shell-quote-argument thread-id))
     "*notmuch-apply-thread-series*")))

;;;###autoload
(defun notmuch-extract-thread-patches-projectile ()
  "Like `notmuch-extract-thread-patches', but use projectile to choose the repo."
  (interactive)
  (mailscripts--projectile-repo-and-branch 'notmuch-extract-thread-patches))

(defun mailscripts--check-out-branch (branch)
  (call-process-shell-command
   (format "git checkout -b %s"
           (shell-quote-argument
            (if mailscripts-extract-patches-branch-prefix
                (concat mailscripts-extract-patches-branch-prefix branch)
              branch)))))

(defun mailscripts--projectile-repo-and-branch (f)
  (let ((repo (projectile-completing-read
               "Select projectile project: " projectile-known-projects))
        (branch (completing-read "Branch name: " nil)))
    (funcall f repo branch)))

(provide 'mailscripts)

;;; mailscripts.el ends here
