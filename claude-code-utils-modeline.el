;;; claude-code-utils-modeline.el --- Modeline display for Claude Code sessions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Shuto Omura

;; Author: Shuto Omura <somura-vanilla@so-icecream.com>
;; Maintainer: Shuto Omura <somura-vanilla@so-icecream.com>
;; URL: https://github.com/so-vanilla/claude-code-utils
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
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

;; Global minor-mode that reads intermediate JSON files written by
;; Claude Code's statusline feature and displays session information
;; (model name, context usage percentage, cost, session duration)
;; in the modeline of claude-code-ide session buffers.

;;; Code:

(require 'json)

(declare-function claude-code-ide--get-buffer-name "claude-code-ide")
(defvar claude-code-ide--processes)

;;;; Customization

(defgroup claude-code-utils-modeline nil
  "Modeline display for Claude Code sessions."
  :group 'claude-code-ide
  :prefix "claude-code-utils-modeline-")

(defcustom claude-code-utils-modeline-data-directory "/tmp/claude-code/"
  "Directory where statusline.sh writes intermediate JSON files."
  :type 'directory)

(defcustom claude-code-utils-modeline-update-interval 3.0
  "Polling interval in seconds for reading intermediate files."
  :type 'number)

(defcustom claude-code-utils-modeline-format-string " %m │ Ctx:%c%% │ $%d │ %t "
  "Format string for modeline display.
%m = model name, %c = context used percentage,
%d = cost in USD, %t = session duration."
  :type 'string)

;;;; Faces

(defface claude-code-utils-modeline-normal
  '((t :inherit mode-line))
  "Face for normal context usage (< 75%).")

(defface claude-code-utils-modeline-context-warning
  '((t :inherit warning))
  "Face for warning context usage (75% - 89%).")

(defface claude-code-utils-modeline-context-critical
  '((t :inherit error))
  "Face for critical context usage (>= 90%).")

;;;; Internal variables

(defvar claude-code-utils-modeline--data-cache (make-hash-table :test 'equal)
  "Cache of parsed JSON data, keyed by project directory.")

(defvar claude-code-utils-modeline--timer nil
  "Timer for periodic data file polling.")

(defvar claude-code-utils-modeline--original-mode-line-formats (make-hash-table :test 'equal)
  "Original mode-line-format values, keyed by buffer name.")

;;;; Data reading

(defun claude-code-utils-modeline--data-file (project-dir)
  "Return the intermediate data file path for PROJECT-DIR."
  (expand-file-name
   (concat (md5 (directory-file-name (file-truename project-dir))) ".json")
   claude-code-utils-modeline-data-directory))

(defun claude-code-utils-modeline--read-data (project-dir)
  "Read and parse the intermediate JSON file for PROJECT-DIR.
Returns parsed data as alist, or nil on failure."
  (let ((file (claude-code-utils-modeline--data-file project-dir)))
    (when (file-readable-p file)
      (condition-case nil
          (let ((json-object-type 'alist)
                (json-key-type 'symbol))
            (json-read-file file))
        (error nil)))))

(defun claude-code-utils-modeline--poll ()
  "Poll all active sessions and update the data cache."
  (when (and (boundp 'claude-code-ide--processes)
             (hash-table-p claude-code-ide--processes))
    (maphash
     (lambda (dir _process)
       (when-let ((data (claude-code-utils-modeline--read-data dir)))
         (puthash dir data claude-code-utils-modeline--data-cache)))
     claude-code-ide--processes))
  (claude-code-utils-modeline--update-all-buffers)
  (force-mode-line-update t))

;;;; Formatting

(defun claude-code-utils-modeline--format-duration (ms)
  "Format MS milliseconds as human-readable duration string."
  (let* ((total-seconds (/ ms 1000))
         (hours (/ total-seconds 3600))
         (minutes (/ (mod total-seconds 3600) 60))
         (seconds (mod total-seconds 60)))
    (cond
     ((>= hours 1) (format "%dh%02dm" hours minutes))
     ((>= minutes 1) (format "%dm%02ds" minutes seconds))
     (t (format "%ds" seconds)))))

(defun claude-code-utils-modeline--format-cost (cost)
  "Format COST in USD for display."
  (if (< cost 0.01)
      (format "%.4f" cost)
    (format "%.2f" cost)))

(defun claude-code-utils-modeline--context-face (percentage)
  "Return the appropriate face for context PERCENTAGE."
  (cond
   ((>= percentage 90) 'claude-code-utils-modeline-context-critical)
   ((>= percentage 75) 'claude-code-utils-modeline-context-warning)
   (t 'claude-code-utils-modeline-normal)))

(defun claude-code-utils-modeline--build-string (model context-used cost duration-ms)
  "Build modeline string from MODEL, CONTEXT-USED, COST, DURATION-MS."
  (let ((result claude-code-utils-modeline-format-string))
    (setq result (string-replace "%m" (format "%s" model) result))
    (setq result (string-replace "%c" (format "%.0f" (float context-used)) result))
    (setq result (string-replace "%d" (claude-code-utils-modeline--format-cost cost) result))
    (setq result (string-replace "%t" (claude-code-utils-modeline--format-duration duration-ms) result))
    result))

(defun claude-code-utils-modeline--format-data (data)
  "Format DATA alist according to `claude-code-utils-modeline-format-string'."
  (let* ((model (or (alist-get 'model data) "?"))
         (context-used (or (alist-get 'context_used data) 0))
         (cost (or (alist-get 'cost_usd data) 0))
         (duration-ms (or (alist-get 'duration_ms data) 0))
         (face (claude-code-utils-modeline--context-face context-used))
         (formatted (claude-code-utils-modeline--build-string
                     model context-used cost duration-ms)))
    (propertize formatted 'face face)))

;;;; Project directory detection

(defun claude-code-utils-modeline--buffer-project-dir (buffer)
  "Find the project directory associated with BUFFER.
Walk `claude-code-ide--processes' and match buffer names."
  (when (and (boundp 'claude-code-ide--processes)
             (hash-table-p claude-code-ide--processes))
    (let ((buf-name (buffer-name buffer))
          (result nil))
      (maphash
       (lambda (dir _process)
         (when (string= buf-name (claude-code-ide--get-buffer-name dir))
           (setq result dir)))
       claude-code-ide--processes)
      result)))

;;;; Modeline construction

(defun claude-code-utils-modeline--mode-line-format (data)
  "Build a complete mode-line-format list showing DATA."
  (list (claude-code-utils-modeline--format-data data)))

(defun claude-code-utils-modeline--apply-to-buffer (buffer)
  "Apply claude-code-utils modeline to BUFFER if it has associated session data."
  (when (buffer-live-p buffer)
    (when-let ((dir (claude-code-utils-modeline--buffer-project-dir buffer)))
      (with-current-buffer buffer
        (unless (gethash (buffer-name buffer) claude-code-utils-modeline--original-mode-line-formats)
          (puthash (buffer-name buffer) mode-line-format
                   claude-code-utils-modeline--original-mode-line-formats))
        (if (featurep 'doom-modeline)
            (claude-code-utils-modeline--apply-doom buffer)
          (when-let ((data (gethash dir claude-code-utils-modeline--data-cache)))
            (setq-local mode-line-format
                        (claude-code-utils-modeline--mode-line-format data))))))))

(defun claude-code-utils-modeline--restore-buffer (buffer)
  "Restore original modeline for BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let ((original (gethash (buffer-name buffer)
                                    claude-code-utils-modeline--original-mode-line-formats)))
        (setq-local mode-line-format original)
        (remhash (buffer-name buffer) claude-code-utils-modeline--original-mode-line-formats)))))

(defun claude-code-utils-modeline--update-all-buffers ()
  "Update modeline for all Claude Code session buffers."
  (dolist (buffer (buffer-list))
    (claude-code-utils-modeline--apply-to-buffer buffer)))

;;;; doom-modeline integration

(with-eval-after-load 'doom-modeline
  (defun doom-modeline-segment--claude-code-utils-info ()
    "Claude Code session information segment."
    (when-let ((dir (claude-code-utils-modeline--buffer-project-dir (current-buffer))))
      (if-let ((data (gethash dir claude-code-utils-modeline--data-cache)))
          (claude-code-utils-modeline--format-data data)
        (propertize " Claude Code ... " 'face 'claude-code-utils-modeline-normal))))
  (add-to-list 'doom-modeline-fn-alist
               '(claude-code-utils-info . doom-modeline-segment--claude-code-utils-info))

  (doom-modeline-def-modeline 'claude-code-utils
    '(bar claude-code-utils-info)
    '())

  (when (bound-and-true-p claude-code-utils-modeline-mode)
    (claude-code-utils-modeline--update-all-buffers)))

(defun claude-code-utils-modeline--apply-doom (buffer)
  "Apply doom-modeline claude-code-utils modeline to BUFFER."
  (with-current-buffer buffer
    (when (fboundp 'doom-modeline-set-modeline)
      (doom-modeline-set-modeline 'claude-code-utils))))

;;;; Window change hook

(defun claude-code-utils-modeline--on-window-change (frame)
  "Re-apply modeline when switching to a Claude Code session buffer in FRAME."
  (when claude-code-utils-modeline-mode
    (let ((buffer (window-buffer (frame-selected-window frame))))
      (claude-code-utils-modeline--apply-to-buffer buffer))))

;;;; Advice for session start

(defun claude-code-utils-modeline--after-start-session (&rest _args)
  "Advice function to apply modeline after a Claude Code session starts.
Runs with a short delay to allow the buffer to be fully set up."
  (run-at-time 1.0 nil #'claude-code-utils-modeline--update-all-buffers))

;;;; Minor mode

;;;###autoload
(define-minor-mode claude-code-utils-modeline-mode
  "Global minor mode to display Claude Code session info in modeline."
  :global t
  :lighter nil
  (if claude-code-utils-modeline-mode
      (progn
        (setq claude-code-utils-modeline--timer
              (run-with-timer 0 claude-code-utils-modeline-update-interval
                              #'claude-code-utils-modeline--poll))
        (with-eval-after-load 'claude-code-ide
          (advice-add 'claude-code-ide--start-session :after
                      #'claude-code-utils-modeline--after-start-session))
        (add-hook 'window-selection-change-functions
                  #'claude-code-utils-modeline--on-window-change)
        (claude-code-utils-modeline--update-all-buffers))
    (when claude-code-utils-modeline--timer
      (cancel-timer claude-code-utils-modeline--timer)
      (setq claude-code-utils-modeline--timer nil))
    (when (featurep 'claude-code-ide)
      (advice-remove 'claude-code-ide--start-session
                     #'claude-code-utils-modeline--after-start-session))
    (remove-hook 'window-selection-change-functions
                 #'claude-code-utils-modeline--on-window-change)
    (dolist (buffer (buffer-list))
      (claude-code-utils-modeline--restore-buffer buffer))
    (clrhash claude-code-utils-modeline--data-cache)
    (clrhash claude-code-utils-modeline--original-mode-line-formats)))

(provide 'claude-code-utils-modeline)
;;; claude-code-utils-modeline.el ends here
