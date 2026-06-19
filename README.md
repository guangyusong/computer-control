# Computer Control

Experimental native macOS shell for realtime voice-driven computer control.

Computer Control combines OpenAI Realtime voice, local macOS Accessibility actions,
Visual Computer Use, a managed Playwright browser, and an optional Live Chrome
extension. It is a developer preview for people who are comfortable running local
automation tools with broad permissions.

## What works

- Realtime voice conversation with interruption/cancel controls.
- Typed command composer with a ChatGPT-style session history.
- Native app actions: open apps, quit apps, keyboard shortcuts, typing, mouse,
  scrolling, menu selection, screenshots, and Accessibility tree inspection.
- Browser tasks through either a managed Playwright Chromium profile or a Live
  Chrome companion extension.
- Gmail demo path: open Compose, fill drafts, and stop before Send.
- Notes demo path: create a note/checklist through native app control.
- Persistent local activity history and per-session context status.

## Safety status

This project defaults to **Power-user mode** for developer preview builds. That
means broad local control is available, but high-impact actions are still blocked
or require explicit confirmation first, including send, submit, buy, pay, delete,
upload, share/post, authentication, credential entry, permission changes, and
destructive filesystem or app actions.

This app is not a consumer-ready remote-control agent. Review the code before
granting permissions.

## Requirements

- macOS 14 or newer.
- Xcode command line tools / SwiftPM.
- Node.js and npm.
- An OpenAI API key with access to the configured Realtime and Responses models.
- Optional: Google Chrome for the Live Chrome extension.

## Setup

```bash
npm ci
cp .env.example .env
```

Put your OpenAI API key in `.env`:

```bash
OPENAI_API_KEY=sk-...
```

You can also put the key by itself in a local `.openai` file. `.env` and
`.openai` are ignored by git.

## Run

```bash
./script/build_and_run.sh
```

The app will request macOS permissions as needed:

- Microphone for Realtime voice.
- Accessibility for keyboard, mouse, app, and UI control.
- Screen Recording for screenshots and Visual Computer Use.
- Automation prompts may appear for individual target apps.

## Live Chrome extension

Load `chrome-extension/` as an unpacked extension:

1. Open `chrome://extensions`.
2. Enable Developer mode.
3. Click **Load unpacked**.
4. Select this repo's `chrome-extension` folder.
5. In Computer Control, press the demo readiness/check button.

The extension exposes tab metadata, DOM snapshots, page clicks/fills/key presses,
visible-tab screenshots, and tab release commands to a transient local bridge on
`127.0.0.1:38433`. It does not request cookies, passwords, browser history, local
storage, or session stores.

## Useful demo commands

- "Start listening."
- "Open Gmail and click Compose."
- "Draft an email to alex@example.com with subject Hello saying I can demo this tomorrow."
- "Stop."
- "Open Notes and write a checklist for this demo."
- "Take a screenshot."
- "Scroll down."

The app should stop before sending email, purchases, deletes, authentication, or
other high-impact actions.

## Checks

```bash
./script/check.sh
./script/build_and_run.sh --verify
./script/validate_release.sh
```

`validate_release.sh` inspects the local app bundle. Developer preview builds are
signed for local development and are not notarized public downloads.

## Privacy

See [PRIVACY.md](PRIVACY.md). In short: prompts, audio, screenshots, browser
snapshots, and tool context may be sent to OpenAI depending on the feature used.
History is stored locally in Application Support. No telemetry is sent by this
app by default.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Please keep safety and privacy boundaries
explicit when expanding automation capabilities.
