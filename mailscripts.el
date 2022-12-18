;;; mailscripts.el --- utilities for handling mail on Unixes  -*- lexical-binding: t; -*-

;; Author: Sean Whitton <spwhitton@spwhitton.name>
;; Version: 27
;; Package-Requires: (notmuch)

;; Copyright (C) 2018, 2019, 2020, 2022 Sean Whitton

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

;;; Commentary:

;; The original purpose of this package was to make it easy to use the small
;; mail-handling utilities shipped in Debian's 'mailscripts' package from
;; within Emacs.  It now also contains some additional, thematically-related
;; utilities which don't invoke any of those scripts.
;;
;; Entry points you might like to look at if you're new to this package:
;; mailscripts-prepare-patch, notmuch-slurp-debbug,
;; notmuch-extract-{thread,message}-patches{,-to-project}.

;;; Code:

(require 'cl-lib)
(require 'notmuch)
(require 'thingatpt)
(require 'vc)
(require 'message)
(require 'gnus)

(defgroup mailscripts nil
  "Customisation of functions in the mailscripts package.")

(defcustom mailscripts-extract-patches-branch-prefix nil
  "Prefix for git branches created by functions which extract patch series.

E.g. `email/'."
  :type 'string
  :group 'mailscripts)

(defcustom mailscripts-detach-head-from-existing-branch nil
  "Whether to detach HEAD before applying patches to an existing branch.

This is useful if you want to manually review the result of
applying patches before updating any of your existing branches,
or for quick, ad hoc testing of a patch series.

Note that this does not prevent the creation of new branches."
  :type '(choice (const :tag "Always detach" t)
		 (const :tag "Never detach" nil)
		 (const :tag "Ask whether to detach" ask))
  :group 'mailscripts)

(defcustom mailscripts-project-library 'project
  "Which project management library to use to choose from known projects.

Some mailscripts functions allow selecting the repository to
which patches will be applied from the list of projects already
known to Emacs.  There is more than one popular library for
maintaining a list of known projects, however, so this variable
must be set to the one you use."
  :type '(choice (const :tag "project.el" project)
		 (const :tag "Projectile" projectile))
  :group 'mailscripts)

;;;###autoload
(defun notmuch-slurp-debbug (bug &optional no-open)
  "Slurp Debian bug with bug number BUG and open the thread in notmuch.

If NO-OPEN, don't open the thread."
  (interactive "sBug number: ")
  (call-process-shell-command (concat "notmuch-slurp-debbug " bug))
  (unless no-open
    (let* ((search (concat "Bug#" bug))
           (thread-id (car (process-lines notmuch-command
                                          "search"
                                          "--output=threads"
                                          "--limit=1"
                                          "--format=text"
                                          "--format-version=4" search))))
      (notmuch-search search t thread-id))))

;;;###autoload
(defun notmuch-slurp-debbug-at-point ()
  "Slurp Debian bug with bug number at point and open the thread in notmuch."
  (interactive)
  (save-excursion
    ;; the bug number might be prefixed with a # or 'Bug#'; try
    ;; skipping over those to see if there's a number afterwards
    (skip-chars-forward "#bBug" (+ 4 (point)))
    (notmuch-slurp-debbug (number-to-string (number-at-point)))))

;;;###autoload
(defun notmuch-slurp-this-debbug ()
  "When viewing a Debian bug in notmuch, download any missing messages."
  (interactive)
  (let ((subject (notmuch-show-get-subject)))
    (notmuch-slurp-debbug
     (if (string-match "Bug#\\([0-9]+\\):" subject)
         (match-string 1 subject)
       (read-string "Bug number: ")) t)
    (notmuch-refresh-this-buffer)))

;;;###autoload
(defun notmuch-extract-thread-patches (repo branch &optional reroll-count)
  "Extract patch series in current thread to branch BRANCH in repo REPO.

The target branch may or may not already exist.

With an optional prefix numeric argument REROLL-COUNT, try to
extract the nth revision of a series.  See the --reroll-count
option detailed in mbox-extract-patch(1).

See notmuch-extract-patch(1) manpage for limitations: in
particular, this Emacs Lisp function supports passing only entire
threads to the notmuch-extract-patch(1) command."
  (interactive
   "Dgit repo: \nsnew branch name (or leave blank to apply to current HEAD): \nP")
  (let ((thread-id
         ;; If `notmuch-show' was called with a notmuch query rather
         ;; than a thread ID, as `org-notmuch-follow-link' in
         ;; org-notmuch.el does, then `notmuch-show-thread-id' might
         ;; be an arbitrary notmuch query instead of a thread ID.  We
         ;; need to wrap such a query in thread:{} before passing it
         ;; to notmuch-extract-patch(1), or we might not get a whole
         ;; thread extracted (e.g. if the query is just id:foo)
         (if (string= (substring notmuch-show-thread-id 0 7) "thread:")
             notmuch-show-thread-id
           (concat "thread:{" notmuch-show-thread-id "}")))
        (default-directory (expand-file-name repo)))
    (mailscripts--check-out-branch branch)
    (shell-command
     (if reroll-count
         (format "notmuch-extract-patch -v%d %s | git am"
                 (prefix-numeric-value reroll-count)
                 (shell-quote-argument thread-id))
       (format "notmuch-extract-patch %s | git am"
               (shell-quote-argument thread-id)))
     "*notmuch-apply-thread-series*")))

;;;###autoload
(define-obsolete-function-alias
  'notmuch-extract-thread-patches-projectile
  'notmuch-extract-thread-patches-to-project
  "mailscripts 0.22")

;;;###autoload
(defun notmuch-extract-thread-patches-to-project ()
  "Like `notmuch-extract-thread-patches', but choose repo from known projects."
  (interactive)
  (mailscripts--project-repo-and-branch
   'notmuch-extract-thread-patches
   (when current-prefix-arg
     (prefix-numeric-value current-prefix-arg))))

;;;###autoload
(defun notmuch-extract-message-patches (repo branch)
  "Extract patches attached to current message to branch BRANCH in repo REPO.

The target branch may or may not already exist.

Patches are applied using git-am(1), so we only consider
attachments with filenames which look like they were generated by
git-format-patch(1)."
  (interactive
   "Dgit repo: \nsnew branch name (or leave blank to apply to current HEAD): ")
  (with-current-notmuch-show-message
   (let ((default-directory (expand-file-name repo))
         (mm-handle (mm-dissect-buffer t)))
     (mailscripts--check-out-branch branch)
     (notmuch-foreach-mime-part
      (lambda (p)
        (let* ((disposition (mm-handle-disposition p))
               (filename (cdr (assq 'filename disposition))))
          (and filename
               (string-match "^\\(v?[0-9]+\\)-.+\\.\\(patch\\|diff\\|txt\\)$"
                             filename)
               (mm-pipe-part p "git am"))))
      mm-handle))))

;;;###autoload
(define-obsolete-function-alias
  'notmuch-extract-message-patches-projectile
  'notmuch-extract-message-patches-to-project
  "mailscripts 0.22")

;;;###autoload
(defun notmuch-extract-message-patches-to-project ()
  "Like `notmuch-extract-message-patches', but choose repo from known projects."
  (interactive)
  (mailscripts--project-repo-and-branch 'notmuch-extract-message-patches))

;;;###autoload
(defun mailscripts-prepare-patch ()
  "Prepare patches for mailing out in a project- and MUA-specific way.
This is a convenience wrapper command for interactive use only.
Its behaviour is subject to change as we add support for more MUAs, ways to
generate patches, etc.."
  (interactive)
  (call-interactively
   (if (eq (vc-deduce-backend) 'Git)
       ;; For Git, default to one message per patch, like git-send-email(1).
       (if (and (local-variable-p 'vc-prepare-patches-separately)
		(not vc-prepare-patches-separately))
	   #'mailscripts-git-format-patch-attach
	 #'mailscripts-git-format-patch-drafts)
     #'vc-prepare-patch)))

;;;###autoload
(defun mailscripts-git-format-patch-attach (args &optional new)
  "Compose mail with patches generated by git-format-patch(1) attached.
ARGS is a single string of arguments to git-format-patch(1).  If NEW is
non-nil (interactively, with a prefix argument), always start composing a
new message.  Otherwise, attach patches to an existing mail composition
buffer.  This is useful for sending patches in reply to bug reports, etc..

This command is a Git-specific alternative to `vc-prepare-patch' with nil
`vc-prepare-patches-separately'.  It makes it easier to take advantage of
various features of git-format-patch(1), such as reroll counts.
For a command for non-nil `vc-prepare-patches-separately', see
`mailscripts-git-format-patch-drafts'.
See also the interactive wrapper command `mailscripts-prepare-patch'."
  (interactive "sgit format-patch \nP")
  (let ((temp (make-temp-file "patches" t))
	(mml-attach-file-at-the-end t)
	patches subject)
    (condition-case err
	(setq patches (apply #'process-lines "git" "format-patch" "-o" temp
			     (split-string-and-unquote args))
	      subject
	      (if (file-exists-p (car patches))
		  (with-temp-buffer
		    (insert-file (car patches))
		    (and-let* ((subject (message-fetch-field "subject")))
		      (if (cdr patches)
			  (and (string-match
				"^\\[\\(.*PATCH.*?\\)\\(?:\\s-+[0-9]+/[0-9]+\\)?\\]\\s-"
				subject)
			       (format "[%s] " (match-string 1 subject)))
			subject)))
		(user-error "git-format-patch(1) created no patch files")))
      (error (delete-directory temp t)
	     (signal (car err) (cdr err))))
    (compose-mail (mailscripts--gfp-addressee) subject nil (not new) nil nil
		  `((delete-directory ,temp t)))
    (mapc #'mml-attach-file patches)
    (when (or (not subject) (cdr patches))
      (message-goto-subject))))

;;;###autoload
(defun mailscripts-git-format-patch-drafts (args)
  "Import patches generated by git-format-patch(1) to your drafts folder.
ARGS is a single string of arguments to git-format-patch(1).

This command is a Git-specific alternative to `vc-prepare-patch' with non-nil
`vc-prepare-patches-separately'.  It makes it easier to take advantage of
various features of git-format-patch(1), such as reroll counts.
For a command for nil `vc-prepare-patches-separately', see
`mailscripts-git-format-patch-attach'.
See also the interactive wrapper command `mailscripts-prepare-patch'."
  (interactive "sgit format-patch ")
  (let ((args (cons "--thread" (split-string-and-unquote args))))
    (when-let ((addressee (mailscripts--gfp-addressee)))
      (push (format "--to=%s" addressee) args))
    (cl-case mail-user-agent
      (gnus-user-agent (mailscripts--gfp-drafts-gnus args))
      (notmuch-user-agent (mailscripts--gfp-drafts-notmuch args))
      (t (user-error "Unsupported mail-user-agent `%s'" mail-user-agent)))))

(defun mailscripts--gfp-drafts-gnus (args)
  (let* ((temp (make-temp-file "patches"))
	 (group (concat "nndoc+ephemeral:" temp))
	 (method `(nndoc ,temp (nndoc-article-type mbox)))
	 (summary (format "*Summary %s*" group))
	 message-id)
    (unwind-protect
	(progn (with-temp-file temp
		 (unless (zerop (apply #'call-process "git" nil t nil
				       "format-patch" "--stdout" args))
		   (user-error "git-format-patch(1) exited non-zero")))
	       (unless (gnus-alive-p) (gnus-no-server))
	       (gnus-group-read-ephemeral-group group method)
	       (setq message-id (gnus-summary-header "message-id"))
	       (gnus-uu-mark-buffer)
	       (gnus-summary-copy-article nil "nndraft:drafts"))
      (when-let ((buffer (get-buffer summary)))
	(with-current-buffer buffer
	  (gnus-summary-exit-no-update t)))
      (delete-file temp))
    (gnus-group-read-group t t "nndraft:drafts")
    (gnus-summary-goto-article message-id)))

(defun mailscripts--gfp-drafts-notmuch (args)
  (let ((temp (make-temp-file "patches" t))
	(insert (cl-list* "insert" (format "--folder=%s" notmuch-draft-folder)
			  "--create-folder" notmuch-draft-tags)))
    (unwind-protect
	(mapc (lambda (patch)
		(unless (zerop (apply #'call-process "notmuch" patch
				      "*notmuch-insert output*" nil insert))
		  (display-buffer "*notmuch-insert output*")
		  (user-error "notmuch-insert(1) exited non-zero")))
	      (apply #'process-lines "git" "format-patch" "-o" temp args))
      (delete-directory temp t)))
  (notmuch-search (format "folder:%s" notmuch-draft-folder)))

(defun mailscripts--gfp-addressee ()
  "Try to find a recipient for the --to argument to git-format-patch(1)."
  (or (and (local-variable-p 'vc-default-patch-addressee)
	   vc-default-patch-addressee)
      (car (process-lines-ignore-status
	    "git" "config" "--get" "format.to"))
      (car (process-lines-ignore-status
	    "git" "config" "--get" "sendemail.to"))))

(defun mailscripts--check-out-branch (branch)
  (if (string= branch "")
      (when (or (eq mailscripts-detach-head-from-existing-branch t)
		(and (eq mailscripts-detach-head-from-existing-branch 'ask)
		     (yes-or-no-p "Detach HEAD before applying patches?")))
        (call-process-shell-command "git checkout --detach"))
    (call-process-shell-command
     (format "git checkout -b %s"
             (shell-quote-argument
              (if mailscripts-extract-patches-branch-prefix
                  (concat mailscripts-extract-patches-branch-prefix branch)
                branch))))))

(defun mailscripts--project-repo-and-branch (f &rest args)
  (let ((repo (cl-case mailscripts-project-library
		(project
		 (require 'project)
		 (project-prompt-project-dir))
		(projectile
		 (require 'projectile)
		 (projectile-completing-read
		  "Select Projectile project: " projectile-known-projects))
		(t
		 (user-error
		  "Please customize variable `mailscripts-project-library'."))))
        (branch (read-from-minibuffer
                 "Branch name (or leave blank to apply to current HEAD): ")))
    (apply f repo branch args)))

(provide 'mailscripts)

;;; mailscripts.el ends here
