# Privacy

Computer Control runs locally, but some features send data to OpenAI APIs.

## Sent to OpenAI

Depending on the feature used, the app may send:

- Voice audio and transcripts for Realtime sessions.
- Typed commands.
- Planned tool/action context.
- Screenshots for Visual Computer Use.
- Browser DOM snapshots or visible-tab screenshots for browser tasks.

## Stored locally

The app stores session/activity history in the user's Application Support
directory. API keys are read from environment variables, `.env`, or `.openai`;
those files are ignored by git.

## Not collected by default

The app does not send telemetry, analytics, or crash reports by default.

The Live Chrome extension does not request cookies, passwords, browser history,
local storage, or session stores.

## User responsibility

This is a developer preview. Review what is on screen before using Visual
Computer Use or browser automation on sensitive pages.
