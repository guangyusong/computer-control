# Security Policy

Computer Control is an experimental developer preview. It can request powerful
local permissions, including Accessibility and Screen Recording.

## Supported versions

Only the current `main` branch is supported during the preview.

## Reporting a vulnerability

Open a private security advisory on GitHub if available, or contact the
maintainer privately before posting details publicly.

Please include:

- Affected commit or release.
- Reproduction steps.
- Expected and actual behavior.
- Whether the issue can trigger actions without user intent.

## Safety boundaries

High-impact actions should be blocked or require explicit confirmation before
execution. This includes sending, submitting, buying, paying, deleting, uploading,
sharing/posting publicly, authentication, credential entry, permission changes,
and destructive filesystem or app actions.

The Chrome extension must not inspect cookies, passwords, local storage, browser
history, or session stores.
