;;; claude-code-utils.el --- Utilities for Claude Code -*- lexical-binding: t; -*-

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

;; claude-code-utils provides utility packages for Claude Code:
;; - Modeline: Display session information in the modeline
;; - Session Status: Track and display per-perspective session state

;;; Code:

(require 'claude-code-utils-modeline)
(require 'claude-code-utils-session-status)

(provide 'claude-code-utils)
;;; claude-code-utils.el ends here
