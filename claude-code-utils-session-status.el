;;; claude-code-utils-session-status.el --- Claude Code session status tracking -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Shuto Omura

;; Author: Shuto Omura <somura-vanilla@so-icecream.com>
;; Maintainer: Shuto Omura <somura-vanilla@so-icecream.com>
;; URL: https://github.com/so-vanilla/claude-code-utils
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (perspective "2.0"))
;; Keywords: tools, convenience

;; This file is NOT part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
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

;; Module that monitors session status files written via Claude Code
;; hooks, and provides Claude Code session state (working/waiting/idle)
;; for each perspective.
;;
;; Uses file-notify (inotify) for directory watching with polling
;; fallback.  Integrates with persp-utils-sidebar to display status
;; indicators in the sidebar.

;;; Code:

(require 'json)
(require 'filenotify)
(require 'perspective)

(declare-function claude-code-ide--get-buffer-name "claude-code-ide")
(defvar claude-code-ide--processes)

;;;; Customization

(defgroup claude-code-utils-session-status nil
  "Claude Code session status tracking."
  :group 'claude-code-ide
  :prefix "claude-code-utils-session-status-")

(defcustom claude-code-utils-session-status-data-directory "/tmp/claude-code-status/"
  "Directory where session-status.sh writes status JSON files."
  :type 'directory)

(defcustom claude-code-utils-session-status-poll-interval 5.0
  "Fallback polling interval in seconds when file-notify is unavailable."
  :type 'number)

;;;; Faces

(defface claude-code-utils-session-status-working
  '((t :foreground "#61afef"))
  "Face for working state (Claude is processing).")

(defface claude-code-utils-session-status-waiting
  '((t :foreground "#e5c07b"))
  "Face for waiting state (awaiting user response).")

(defface claude-code-utils-session-status-idle
  '((t :foreground "#98c379"))
  "Face for idle state (ready for input).")

(defface claude-code-utils-session-status-none
  '((t :foreground "#5c6370"))
  "Face for no session state.")

;;;; Internal variables

(defvar claude-code-utils-session-status--cache (make-hash-table :test 'equal)
  "Cache of session status data, keyed by project-dir.")

(defvar claude-code-utils-session-status--file-watch nil
  "File notify descriptor for the status directory.")

(defvar claude-code-utils-session-status--poll-timer nil
  "Fallback polling timer.")

(defvar claude-code-utils-session-status--change-hook nil
  "Hook run when any session status changes.
Called with no arguments.")

;;;; Data reading

(defun claude-code-utils-session-status--data-file (project-dir)
  "Return the status file path for PROJECT-DIR."
  (expand-file-name
   (concat (md5 (directory-file-name (file-truename project-dir))) ".json")
   claude-code-utils-session-status-data-directory))

(defun claude-code-utils-session-status--read-file (file)
  "Read and parse status JSON FILE.
Returns parsed data as alist, or nil on failure."
  (when (file-readable-p file)
    (condition-case nil
        (let ((json-object-type 'alist)
              (json-key-type 'symbol))
          (json-read-file file))
      (error nil))))

(defun claude-code-utils-session-status--update-from-file (file)
  "Update cache from status FILE.  Return non-nil if changed."
  (let* ((data (claude-code-utils-session-status--read-file file))
         (project-dir (when data (alist-get 'project_dir data)))
         (new-timestamp (when data (alist-get 'timestamp data)))
         (old-data (when project-dir
                     (gethash project-dir claude-code-utils-session-status--cache)))
         (old-timestamp (when old-data (alist-get 'timestamp old-data))))
    (when (and project-dir data
              (or (null old-timestamp)
                  (null new-timestamp)
                  (>= new-timestamp old-timestamp)))
      (puthash project-dir data claude-code-utils-session-status--cache)
      t)))

(defun claude-code-utils-session-status--handle-deletion (file)
  "Handle deletion of status FILE by removing from cache."
  (let ((basename (file-name-sans-extension (file-name-nondirectory file)))
        (dirs-to-remove nil))
    (maphash
     (lambda (dir _data)
       (when (string= (md5 (directory-file-name dir)) basename)
         (push dir dirs-to-remove)))
     claude-code-utils-session-status--cache)
    (dolist (dir dirs-to-remove)
      (remhash dir claude-code-utils-session-status--cache))
    (consp dirs-to-remove)))

(defun claude-code-utils-session-status--scan-directory ()
  "Scan the status directory and update all cached data."
  (let ((dir claude-code-utils-session-status-data-directory)
        (changed nil))
    (when (file-directory-p dir)
      ;; Update from existing files
      (dolist (file (directory-files dir t "\\.json\\'"))
        (when (claude-code-utils-session-status--update-from-file file)
          (setq changed t)))
      ;; Remove stale entries whose files no longer exist
      (let ((stale-dirs nil))
        (maphash
         (lambda (project-dir _data)
           (unless (file-exists-p (claude-code-utils-session-status--data-file project-dir))
             (push project-dir stale-dirs)))
         claude-code-utils-session-status--cache)
        (dolist (dir stale-dirs)
          (remhash dir claude-code-utils-session-status--cache)
          (setq changed t))))
    (when changed
      (run-hooks 'claude-code-utils-session-status--change-hook))))

;;;; File notify

(defun claude-code-utils-session-status--on-notify (event)
  "Handle file-notify EVENT for the status directory."
  (let ((action (nth 1 event))
        (file (nth 2 event)))
    (when (eq action 'renamed)
      (setq file (nth 3 event)))
    (when (and file (string-suffix-p ".json" file))
      (let ((changed
             (pcase action
               ((or 'created 'changed 'renamed)
                (claude-code-utils-session-status--update-from-file file))
               ('deleted
                (claude-code-utils-session-status--handle-deletion file))
               (_ nil))))
        (when changed
          (run-hooks 'claude-code-utils-session-status--change-hook))))))

(defun claude-code-utils-session-status--start-watching ()
  "Start watching the status directory."
  (let ((dir claude-code-utils-session-status-data-directory))
    (make-directory dir t)
    (condition-case nil
        (setq claude-code-utils-session-status--file-watch
              (file-notify-add-watch
               dir '(change)
               #'claude-code-utils-session-status--on-notify))
      (error nil))
    ;; inotify 成否に関わらずポーリングも起動
    (setq claude-code-utils-session-status--poll-timer
          (run-with-timer 0 claude-code-utils-session-status-poll-interval
                          #'claude-code-utils-session-status--scan-directory))
    (claude-code-utils-session-status--scan-directory)))

(defun claude-code-utils-session-status--stop-watching ()
  "Stop watching the status directory."
  (when claude-code-utils-session-status--file-watch
    (file-notify-rm-watch claude-code-utils-session-status--file-watch)
    (setq claude-code-utils-session-status--file-watch nil))
  (when claude-code-utils-session-status--poll-timer
    (cancel-timer claude-code-utils-session-status--poll-timer)
    (setq claude-code-utils-session-status--poll-timer nil)))

;;;; Perspective mapping

(defun claude-code-utils-session-status--persp-project-dir (persp-name)
  "Find the project directory for PERSP-NAME via Claude Code session buffers."
  (when (and (boundp 'claude-code-ide--processes)
             (hash-table-p claude-code-ide--processes))
    (let ((persp (gethash persp-name (perspectives-hash)))
          (result nil))
      (when persp
        (maphash
         (lambda (dir _process)
           (unless result
             (let ((buf-name (claude-code-ide--get-buffer-name dir)))
               (when (and buf-name
                          (let ((buf (get-buffer buf-name)))
                            (and buf (memq buf (persp-buffers persp)))))
                 (setq result dir)))))
         claude-code-ide--processes))
      result)))

;;;; Public API

(defun claude-code-utils-session-status-get (persp-name)
  "Get the session status for PERSP-NAME.
Returns \"working\", \"waiting\", \"idle\", or nil if no session."
  (when-let ((dir (claude-code-utils-session-status--persp-project-dir persp-name)))
    (when-let ((data (gethash (directory-file-name (file-truename dir)) claude-code-utils-session-status--cache)))
      (alist-get 'state data))))

(defun claude-code-utils-session-status-format (persp-name)
  "Format the session status for PERSP-NAME as a propertized string.
Returns a colored indicator string.  When `claude-code-utils-session-status-mode' is
active but no session exists, returns a \"no session\" indicator."
  (let ((status (claude-code-utils-session-status-get persp-name)))
    (if status
        (let ((face (pcase status
                      ("working" 'claude-code-utils-session-status-working)
                      ("waiting" 'claude-code-utils-session-status-waiting)
                      ("idle" 'claude-code-utils-session-status-idle)
                      (_ 'claude-code-utils-session-status-idle)))
              (label (pcase status
                       ("working" "working")
                       ("waiting" "waiting")
                       ("idle" "idle")
                       (_ status))))
          (propertize (format "● %s" label) 'face face))
      (when claude-code-utils-session-status-mode
        (propertize "○ no session" 'face 'claude-code-utils-session-status-none)))))

;;;; Minor mode

;;;###autoload
(define-minor-mode claude-code-utils-session-status-mode
  "Global minor mode to track Claude Code session status."
  :global t
  :lighter nil
  (if claude-code-utils-session-status-mode
      (claude-code-utils-session-status--start-watching)
    (claude-code-utils-session-status--stop-watching)
    (clrhash claude-code-utils-session-status--cache)))

(provide 'claude-code-utils-session-status)
;;; claude-code-utils-session-status.el ends here
