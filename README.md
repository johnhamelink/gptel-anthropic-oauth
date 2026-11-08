# gptel-oauth

> **⚠️ Warning:** Use at your own risk. We cannot guarantee that the use of this package is compliant with Anthropic's or OpenAI's Terms of Service.

An OAuth (PKCE) backend for [gptel](https://github.com/karthink/gptel), giving access to **Claude** via a **Claude Pro/Max** subscription — no API key needed. The token is saved to disk and automatically refreshed before requests.

OpenAI Codex is now supported by gptel itself; see [below](#openai-codex).

---

## Requirements

- Emacs 28.1+
- A version of [gptel](https://github.com/karthink/gptel) that ships `gptel-oauth.el` (MELPA 20261018 or later)

---

## Installation

### Manual

Clone this repository and add it to your `load-path`:

```emacs-lisp
(add-to-list 'load-path "/path/to/gptel-oauth")
(require 'gptel-anthropic-oauth)
```

### use-package (straight.el)

```emacs-lisp
(use-package gptel-anthropic-oauth
  :straight (:host github :repo "colobas/gptel-oauth")
  :after gptel)
```

---

## Usage

### Anthropic (Claude Pro/Max)

**1. Log in once:**

```
M-x gptel-anthropic-oauth-login
```

This opens a browser to `claude.ai`. After authorizing, paste the authorization code (or the full redirect URL) back into the Emacs minibuffer.

**2. Create a backend:**

<!-- @models.dev:anthropic -->
```emacs-lisp
(gptel-make-anthropic-oauth "Claude-OAuth"
  :stream t
  :models '(claude-sonnet-4-6 claude-opus-4-6))
```
<!-- @/models.dev:anthropic -->

---

### OpenAI Codex

Use gptel's built-in support: `M-x gptel-openai-oauth-login` and `gptel-make-openai-oauth`. It stores its token separately and its default model list is maintained by gptel.

`gptel-make-codex` and `gptel-oauth-login-codex` remain as obsolete aliases for those functions. `gptel-make-codex` no longer accepts `:key`, and streaming is now on by default.

---

## Logging out

```
M-x gptel-anthropic-oauth-logout
```

This removes the stored Anthropic token from disk.

---

## Token storage

The access token, refresh token and expiry are stored, readable only by you, in:

```
~/.config/gptel/anthropic-oauth-token
```

The path respects `$XDG_CONFIG_HOME` if set. It can be customized via:

```emacs-lisp
(setq gptel-anthropic-oauth-token-file "/your/custom/path/anthropic-oauth-token")
```

Tokens are automatically refreshed 5 minutes before expiry.

### Upgrading from 0.1

The feature is now `gptel-anthropic-oauth`, because gptel ships its own `gptel-oauth`. Update your `require` or `use-package` form, then log in again. The old `~/.config/gptel/oauth-credentials.json` is no longer used and can be deleted.

---

## How it works

The login uses **OAuth 2.0 with PKCE** (Proof Key for Code Exchange), and redirects to `console.anthropic.com`; you paste the `code#state` or full redirect URL back into Emacs. PKCE and token-file helpers come from gptel's `gptel-oauth` library.

---

## License

MIT
