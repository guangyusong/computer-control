# Contributing

Thanks for helping improve Computer Control.

## Local checks

Run:

```bash
npm ci
./script/check.sh
```

For app-bundle validation:

```bash
./script/build_and_run.sh --verify
./script/validate_release.sh
```

## Safety expectations

- Keep high-impact actions gated by the central safety policy.
- Do not add cookie, password, local storage, browser history, or session-store
  access to the Chrome extension.
- Prefer narrow tools and explicit status rows over silent broad automation.
- Document any new data sent to OpenAI or stored locally.

## Pull requests

Include:

- What changed.
- How it was tested.
- Any new permissions, data flows, or safety implications.
