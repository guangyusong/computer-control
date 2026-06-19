# Computer Control Live Chrome Extension

Load this folder as an unpacked Chrome extension:

1. Open `chrome://extensions`.
2. Enable Developer mode.
3. Click Load unpacked.
4. Select this `chrome-extension` folder.
5. In the native app, press Demo Check.

The extension only exposes tab metadata, DOM snapshots, page clicks/fills/key presses,
visible-tab screenshots, and tab release commands to the local bridge at
`http://127.0.0.1:38433`. It does not request cookie, password, local storage, or
history permissions.

## Permissions

This developer-preview extension requests broad page access so the native app can
claim an already-open tab and use DOM selectors on arbitrary web apps. It should
not be treated as a consumer extension yet.

The extension does not inspect cookies, passwords, browser history, local
storage, or session stores. The local bridge is started by the native app for
status/task checks and listens on `127.0.0.1`.

High-impact controls such as Send, Submit, Buy, Pay, Delete, Upload, Share, or
Post should be blocked by the native safety policy and the Live Chrome runner.
