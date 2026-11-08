;;; gptel-anthropic-oauth.el --- Claude Pro/Max OAuth backend for gptel  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Guilherme Pires

;; Version: 0.2.0
;; Package-Requires: ((emacs "28.1") (gptel "20261018.848"))
;; Keywords: convenience, tools
;; URL: https://github.com/colobas/gptel-oauth

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

;; A gptel backend for Claude Pro/Max subscriptions, using OAuth (PKCE):
;;
;;    M-x gptel-anthropic-oauth-login     ; one-time login
;;    (gptel-make-anthropic-oauth "Claude-OAuth"
;;      :stream t
;;      :models '(claude-sonnet-4-6 claude-opus-4-6))
;;
;; The token is saved to `gptel-anthropic-oauth-token-file' and refreshed
;; automatically before requests.
;;
;; OAuth utilities come from gptel's own `gptel-oauth' library.  OpenAI Codex
;; is handled by gptel itself; see `gptel-make-openai-oauth'.  The old Codex
;; entry points here are obsolete aliases for gptel's commands.

;;; Code:

(require 'cl-lib)
(require 'url-util)
(require 'gptel)
(require 'gptel-anthropic)
(require 'gptel-oauth)
(require 'gptel-openai-oauth)

(defcustom gptel-anthropic-oauth-token-file
  (expand-file-name "gptel/anthropic-oauth-token"
                    (or (getenv "XDG_CONFIG_HOME") "~/.config"))
  "File in which the Anthropic OAuth token is stored."
  :type 'file
  :group 'gptel)

(defvar gptel-anthropic-oauth--token nil
  "Cached token plist, with :access_token :refresh_token :expires_at.")

(defconst gptel-anthropic-oauth--client-id
  (base64-decode-string "OWQxYzI1MGEtZTYxYi00NGQ5LTg4ZWQtNTk0NGQxOTYyZjVl")
  "Anthropic OAuth client ID for Claude Pro/Max.")

(defconst gptel-anthropic-oauth--authorize-url
  "https://claude.ai/oauth/authorize")
(defconst gptel-anthropic-oauth--token-url
  "https://console.anthropic.com/v1/oauth/token")
(defconst gptel-anthropic-oauth--redirect-uri
  "https://console.anthropic.com/oauth/code/callback")
(defconst gptel-anthropic-oauth--scopes
  "org:create_api_key user:profile user:inference")

(defconst gptel-anthropic-oauth--refresh-margin 300
  "Refresh the token when it has fewer than this many seconds left.")

(defconst gptel-anthropic-oauth--claude-code-version "2.1.2"
  "Version string sent in the User-Agent for Claude Code identity.")

;;; Token handling

(defun gptel-anthropic-oauth--store (token)
  "Cache TOKEN and write it to a file readable only by the user."
  (with-file-modes #o700
    (make-directory (file-name-directory gptel-anthropic-oauth-token-file) t))
  (with-file-modes #o600
    (gptel-oauth--write-token gptel-anthropic-oauth-token-file token))
  ;; `with-file-modes' does not affect a file that already exists.
  (set-file-modes gptel-anthropic-oauth-token-file #o600)
  (setq gptel-anthropic-oauth--token token))

(defun gptel-anthropic-oauth--request-token (data)
  "POST DATA to the token endpoint, then store and return the new token.
`gptel--url-retrieve' ignores the HTTP status, so a response without
tokens is treated as failure."
  (let* ((response (gptel--url-retrieve gptel-anthropic-oauth--token-url
                     :method 'post :data data))
         (access (plist-get response :access_token))
         (refresh (plist-get response :refresh_token))
         (expires-in (plist-get response :expires_in)))
    (unless (and access refresh expires-in)
      (error "Anthropic token request failed: %S"
             (or (plist-get response :error_description)
                 (plist-get response :error)
                 "no tokens returned")))
    (gptel-anthropic-oauth--store
     (list :access_token access
           :refresh_token refresh
           :expires_at (+ (float-time) expires-in)))))

(defun gptel-anthropic-oauth--ensure-token ()
  "Return a valid token plist, loading or refreshing it if needed."
  (let ((token (or gptel-anthropic-oauth--token
                   (setq gptel-anthropic-oauth--token
                         (gptel-oauth--read-token
                          gptel-anthropic-oauth-token-file))
                   (user-error "No Anthropic OAuth token; run `gptel-anthropic-oauth-login'"))))
    (if (> (plist-get token :expires_at)
           (+ (float-time) gptel-anthropic-oauth--refresh-margin))
        token
      (condition-case err
          (gptel-anthropic-oauth--request-token
           (list :grant_type "refresh_token"
                 :client_id gptel-anthropic-oauth--client-id
                 :refresh_token (plist-get token :refresh_token)))
        (error
         (user-error "Anthropic token refresh failed (%s); run `gptel-anthropic-oauth-login'"
                     (error-message-string err)))))))

(defun gptel-anthropic-oauth--key ()
  "Return the current OAuth access token."
  (plist-get (gptel-anthropic-oauth--ensure-token) :access_token))

;;; Login

(defun gptel-anthropic-oauth--authorization-url (verifier state)
  "Return the authorization URL for PKCE VERIFIER and STATE."
  (concat
   gptel-anthropic-oauth--authorize-url "?"
   (url-build-query-string
    `(("code" "true")
      ("client_id" ,gptel-anthropic-oauth--client-id)
      ("response_type" "code")
      ("redirect_uri" ,gptel-anthropic-oauth--redirect-uri)
      ("scope" ,gptel-anthropic-oauth--scopes)
      ("code_challenge" ,(gptel-oauth--generate-code-challenge verifier))
      ("code_challenge_method" "S256")
      ("state" ,state)))))

(defun gptel-anthropic-oauth--parse-code (input)
  "Return (CODE . STATE) from INPUT, a CODE#STATE string or redirect URL."
  (let ((input (string-trim input)))
    (if (string-match "[?&]code=\\([^&#]+\\)" input)
        (let ((code (match-string 1 input)))
          (cons code (and (string-match "[?&#]state=\\([^&#]+\\)" input)
                          (match-string 1 input))))
      (let ((parts (split-string input "#")))
        (cons (car parts) (cadr parts))))))

;;;###autoload
(defun gptel-anthropic-oauth-login ()
  "Authenticate gptel with a Claude Pro/Max subscription.

Opens a browser to claude.ai, then prompts for the authorization code
or full redirect URL.  Afterwards, create a backend with
`gptel-make-anthropic-oauth'."
  (interactive)
  (let* ((verifier (gptel-oauth--generate-code-verifier))
         (state (secure-hash 'sha256 (format "%s%s" (float-time) (random)))))
    (browse-url (gptel-anthropic-oauth--authorization-url verifier state))
    (pcase-let ((`(,code . ,returned-state)
                 (gptel-anthropic-oauth--parse-code
                  (read-string "Paste the authorization code or redirect URL: "))))
      (when (string-empty-p code)
        (user-error "No authorization code entered"))
      (when (and returned-state (not (equal returned-state state)))
        (user-error "OAuth state mismatch; please log in again"))
      (gptel-anthropic-oauth--request-token
       (list :grant_type "authorization_code"
             :client_id gptel-anthropic-oauth--client-id
             :code code
             :state state
             :redirect_uri gptel-anthropic-oauth--redirect-uri
             :code_verifier verifier))
      (message "Successfully logged in to Anthropic OAuth."))))

;;;###autoload
(defun gptel-anthropic-oauth-logout ()
  "Forget the Anthropic OAuth token and delete its file."
  (interactive)
  (setq gptel-anthropic-oauth--token nil)
  (when (file-exists-p gptel-anthropic-oauth-token-file)
    (delete-file gptel-anthropic-oauth-token-file))
  (message "Logged out of Anthropic OAuth."))

;;; Backend

(cl-defstruct (gptel-anthropic-oauth
               (:constructor gptel--make-anthropic-oauth)
               (:copier nil)
               (:include gptel-anthropic)))

(defun gptel-anthropic-oauth--header (_info)
  "Return Bearer auth and Claude Code identity headers."
  (when-let* ((token (gptel--get-api-key)))
    `(("Authorization" . ,(concat "Bearer " token))
      ("anthropic-version" . "2023-06-01")
      ("anthropic-beta"
       . ,(concat "claude-code-20250219,oauth-2025-04-20,"
                  "fine-grained-tool-streaming-2025-05-14,"
                  "interleaved-thinking-2025-05-14,"
                  "extended-cache-ttl-2025-04-11"))
      ("user-agent"
       . ,(concat "claude-cli/" gptel-anthropic-oauth--claude-code-version
                  " (external, cli)"))
      ("x-app" . "cli"))))

(cl-defmethod gptel--request-data ((backend gptel-anthropic-oauth) prompts)
  "Return request data for BACKEND and PROMPTS, with the identity system block."
  (let* ((plist (cl-call-next-method backend prompts))
         (system (plist-get plist :system))
         (identity '(:type "text"
                     :text "You are Claude Code, Anthropic's official CLI for Claude.")))
    (plist-put plist :system
               (cond
                ((vectorp system) (vconcat (vector identity) system))
                ((stringp system)
                 (vector identity `(:type "text" :text ,system)))
                (t (vector identity))))
    plist))

;;;###autoload
(cl-defun gptel-make-anthropic-oauth
    (name &key curl-args stream request-params
          (key #'gptel-anthropic-oauth--key)
          (header #'gptel-anthropic-oauth--header)
          (models gptel--anthropic-models)
          (host "api.anthropic.com")
          (protocol "https")
          (endpoint "/v1/messages"))
  "Register an Anthropic backend using Claude Pro/Max OAuth, with NAME.

Run `gptel-anthropic-oauth-login' once to obtain a token.

The keyword arguments are those of `gptel-make-anthropic', except that
KEY and HEADER default to their OAuth equivalents."
  (declare (indent 1))
  (let ((backend (gptel--make-anthropic-oauth
                  :curl-args curl-args
                  :name name
                  :host host
                  :header header
                  :key key
                  :models (gptel--process-models models)
                  :protocol protocol
                  :endpoint endpoint
                  :stream stream
                  :request-params request-params
                  :url (if protocol
                           (concat protocol "://" host endpoint)
                         (concat host endpoint)))))
    (prog1 backend
      (setf (alist-get name gptel--known-backends nil nil #'equal) backend))))

;;; Compatibility

;; gptel does not autoload its login command, which the alias below needs
;; before this file is loaded.
;;;###autoload (autoload 'gptel-openai-oauth-login "gptel-openai-oauth" nil t)

;;;###autoload
(define-obsolete-function-alias 'gptel-make-codex
  #'gptel-make-openai-oauth "0.2.0")

;;;###autoload
(define-obsolete-function-alias 'gptel-oauth-login-codex
  #'gptel-openai-oauth-login "0.2.0")

;;;###autoload
(define-obsolete-function-alias 'gptel-oauth-login-anthropic
  #'gptel-anthropic-oauth-login "0.2.0")

(provide 'gptel-anthropic-oauth)
;;; gptel-anthropic-oauth.el ends here
