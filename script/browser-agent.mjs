#!/usr/bin/env node
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import OpenAI from "openai";
import { chromium } from "playwright";

const DEFAULT_VIEWPORT = { width: 1440, height: 900 };
const MAX_TEXT = 8000;

async function main() {
  if (process.argv.includes("--self-test")) {
    const result = await withBrowser(async ({ page, steps }) => {
      await page.goto("data:text/html,<title>Browser Agent Self Test</title><main><h1>Browser Agent Self Test</h1><label>Name <input aria-label='Name'></label><button>Compose</button></main>", { waitUntil: "domcontentloaded" });
      steps.push("Opened local self-test page in managed Chromium.");
      await page.getByLabel("Name").fill("Codex");
      steps.push("Filled test field by label.");
      await page.getByRole("button", { name: "Compose" }).click();
      steps.push("Clicked test button by role/name.");
      const title = await page.title();
      const text = await page.locator("body").innerText().catch(() => "");
      return okResult({
        spokenText: "Browser self-test passed.",
        detail: `Opened ${title}. ${text.slice(0, 120)}`,
        steps,
        finalURL: page.url(),
      });
    });
    writeResult(result);
    return;
  }

  const request = await readRequest();
  const goal = String(request.text || request.goal || "").trim();
  if (!goal) {
    writeResult(blockedResult("I need a browser task.", "Browser request did not include text."));
    return;
  }

  const result = await withBrowser(request, async ({ page, context, steps, userDataDir, browserLabel }) => {
    if (isGmailTask(goal)) {
      return runGmailTask({ page, steps, goal, browserLabel });
    }

    return runModelBrowserTask({
      page,
      context,
      steps,
      goal,
      url: request.url,
      maxSteps: clampInt(request.maxSteps, 1, 30, 12),
      userDataDir,
    });
  });

  writeResult(result);
}

async function withBrowser(requestOrFn, maybeFn) {
  const request = typeof requestOrFn === "function" ? {} : requestOrFn;
  const fn = typeof requestOrFn === "function" ? requestOrFn : maybeFn;
  const launchConfig = await browserLaunchConfig(request);
  await fs.mkdir(launchConfig.userDataDir, { recursive: true });

  let context;
  const steps = [...launchConfig.steps];
  try {
    context = await chromium.launchPersistentContext(launchConfig.userDataDir, {
      headless: false,
      viewport: DEFAULT_VIEWPORT,
      channel: launchConfig.channel,
      args: [
        `--window-size=${DEFAULT_VIEWPORT.width},${DEFAULT_VIEWPORT.height}`,
        ...launchConfig.args,
      ],
    });

    const page = context.pages()[0] || await context.newPage();
    page.setDefaultTimeout(8000);
    const result = await fn({
      page,
      context,
      steps,
      userDataDir: launchConfig.userDataDir,
      launchConfig,
      browserLabel: browserContextLabel(launchConfig),
    });
    return result;
  } catch (error) {
    return blockedResult("Browser automation failed.", browserLaunchErrorMessage(error, launchConfig), steps);
  } finally {
    await context?.close().catch(() => {});
  }
}

async function runGmailTask({ page, steps, goal, browserLabel }) {
  const parsed = parseEmailDraft(goal);
  const justCompose = /\b(click|open|show)\b.*\bcompose\b/i.test(goal) && !/\b(draft|write|compose an email|compose email)\b/i.test(goal);

  await page.goto("https://mail.google.com/mail/u/0/#inbox", { waitUntil: "domcontentloaded" });
  steps.push(`Opened Gmail in ${browserLabel}.`);
  await page.waitForTimeout(1200);

  if (await looksLikeLoginPage(page)) {
    steps.push(`Gmail asked for login; waiting up to 2 minutes for ${browserLabel} to finish signing in.`);
    await waitForGmailLogin(page);
    if (await looksLikeLoginPage(page)) {
      return blockedResult(
        "Gmail needs you to log in first.",
        "The selected browser profile is not logged into Gmail yet. I waited for login, then stopped without guessing or continuing.",
        steps,
        page.url()
      );
    }
  }

  await clickCompose(page, steps);

  if (justCompose) {
    return okResult({
      spokenText: "Opened Gmail compose.",
      detail: `Gmail compose is open in ${browserLabel}.`,
      steps,
      finalURL: page.url(),
    });
  }

  const missing = [];
  if (!parsed.recipient) missing.push("recipient email address");
  if (!parsed.subject) missing.push("subject");
  if (!parsed.body) missing.push("message body");
  if (missing.length > 0) {
    return blockedResult(
      `I need the ${joinHuman(missing)} before I can draft that email.`,
      `Missing email fields: ${missing.join(", ")}. Compose is open; no fields were guessed.`,
      steps,
      page.url()
    );
  }

  await fillGmailDraft(page, parsed, steps);
  return okResult({
    spokenText: "Drafted the email and stopped before sending.",
    detail: `Drafted to ${parsed.recipient} with subject "${parsed.subject}". Send was not clicked.`,
    steps,
    finalURL: page.url(),
  });
}

async function runModelBrowserTask({ page, context, steps, goal, url, maxSteps, userDataDir }) {
  if (!process.env.OPENAI_API_KEY) {
    return blockedResult("I need an OpenAI API key before I can run browser selection.", "OPENAI_API_KEY is missing.", steps, page.url());
  }

  const client = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
  const model = process.env.BROWSER_AGENT_MODEL || "gpt-5.5";
  if (url) {
    await page.goto(normalizeURL(url), { waitUntil: "domcontentloaded" });
    steps.push(`Opened ${page.url()}.`);
  }

  const tools = browserTools();
  let response = await client.responses.create({
    model,
    store: false,
    input: [
      {
        role: "system",
        content: [
          {
            type: "input_text",
            text: browserInstructions(),
          },
        ],
      },
      {
        role: "user",
        content: [
          {
            type: "input_text",
            text: goal,
          },
        ],
      },
    ],
    tools,
  });

  for (let step = 0; step < maxSteps; step += 1) {
    const calls = functionCalls(response);
    if (calls.length === 0) {
      return okResult({
        spokenText: "Finished the browser task.",
        detail: outputText(response) || "Browser task finished.",
        steps,
        finalURL: page.url(),
      });
    }

    const outputs = [];
    for (const call of calls) {
      const output = await executeBrowserTool({ call, page, context, steps, userDataDir });
      outputs.push({
        type: "function_call_output",
        call_id: call.call_id,
        output: JSON.stringify(output),
      });
    }

    response = await client.responses.create({
      model,
      store: false,
      previous_response_id: response.id,
      input: outputs,
      tools,
    });
  }

  return blockedResult("I stopped after the browser step limit.", `Reached ${maxSteps} browser-agent steps.`, steps, page.url());
}

function browserTools() {
  return [
    {
      type: "function",
      name: "browser_navigate",
      description: "Navigate the browser to a URL.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          url: { type: "string" },
        },
        required: ["url"],
      },
    },
    {
      type: "function",
      name: "browser_snapshot",
      description: "Return a compact text and accessibility snapshot of the current page.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {},
        required: [],
      },
    },
    {
      type: "function",
      name: "browser_click",
      description: "Click an element using a role/name, visible text, or CSS selector. Prefer role/name or text.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          role: { type: ["string", "null"] },
          name: { type: ["string", "null"] },
          text: { type: ["string", "null"] },
          selector: { type: ["string", "null"] },
          exact: { type: "boolean" },
        },
        required: ["role", "name", "text", "selector", "exact"],
      },
    },
    {
      type: "function",
      name: "browser_fill",
      description: "Fill an input or editable field using a label, role/name, visible text, or CSS selector.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          label: { type: ["string", "null"] },
          role: { type: ["string", "null"] },
          name: { type: ["string", "null"] },
          selector: { type: ["string", "null"] },
          text: { type: "string" },
        },
        required: ["label", "role", "name", "selector", "text"],
      },
    },
    {
      type: "function",
      name: "browser_press",
      description: "Press a keyboard key or chord in the page, such as Enter, Escape, Meta+K, or Control+Tab.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          key: { type: "string" },
        },
        required: ["key"],
      },
    },
    {
      type: "function",
      name: "browser_screenshot",
      description: "Capture a screenshot and return its path.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {},
        required: [],
      },
    },
    {
      type: "function",
      name: "browser_wait",
      description: "Wait for UI changes.",
      parameters: {
        type: "object",
        additionalProperties: false,
        properties: {
          ms: { type: "integer" },
        },
        required: ["ms"],
      },
    },
  ];
}

function browserInstructions() {
  return `
You control a managed Playwright browser through constrained tools.
Use browser_snapshot before choosing selectors unless the next action is obvious.
Prefer role/name, label, or visible text over CSS selectors.
Never click Send, Buy, Delete, Confirm, Submit, or other high-impact buttons. Stop and ask for confirmation instead.
For Gmail, you may open compose and fill a draft, but never send it.
If login or missing information blocks the task, explain exactly what the user must do next.
Return a concise final answer with what changed and what is still pending.
`;
}

async function executeBrowserTool({ call, page, context, steps, userDataDir }) {
  const args = parseArguments(call.arguments);
  try {
    switch (call.name) {
    case "browser_navigate": {
      const url = normalizeURL(args.url);
      await page.goto(url, { waitUntil: "domcontentloaded" });
      steps.push(`Navigated to ${page.url()}.`);
      return { ok: true, url: page.url(), title: await page.title() };
    }
    case "browser_snapshot": {
      const snapshot = await pageSnapshot(page);
      steps.push("Read browser snapshot.");
      return { ok: true, ...snapshot };
    }
    case "browser_click": {
      guardHighImpact(args.name || args.text || args.selector || "");
      const locator = locatorFromArgs(page, args);
      await locator.first().click();
      steps.push(`Clicked ${args.name || args.text || args.selector || args.role || "element"}.`);
      return { ok: true, url: page.url() };
    }
    case "browser_fill": {
      const locator = fillLocatorFromArgs(page, args);
      await locator.first().fill(args.text);
      steps.push(`Filled ${args.label || args.name || args.selector || "field"}.`);
      return { ok: true };
    }
    case "browser_press": {
      await page.keyboard.press(args.key);
      steps.push(`Pressed ${args.key}.`);
      return { ok: true };
    }
    case "browser_screenshot": {
      const screenshotPath = await saveScreenshot(page, userDataDir);
      steps.push(`Captured screenshot ${screenshotPath}.`);
      return { ok: true, screenshotPath };
    }
    case "browser_wait": {
      const ms = clampInt(args.ms, 100, 8000, 1000);
      await page.waitForTimeout(ms);
      steps.push(`Waited ${ms}ms.`);
      return { ok: true };
    }
    default:
      return { ok: false, error: `Unsupported tool ${call.name}` };
    }
  } catch (error) {
    return { ok: false, error: errorMessage(error), snapshot: await pageSnapshot(page).catch(() => null) };
  }
}

async function clickCompose(page, steps) {
  const candidates = [
    () => page.getByRole("button", { name: /compose/i }),
    () => page.getByText(/^compose$/i),
    () => page.locator('[gh="cm"]'),
    () => page.locator('[aria-label*="Compose"]'),
  ];

  for (const candidate of candidates) {
    const locator = candidate();
    try {
      await locator.first().click({ timeout: 5000 });
      steps.push("Clicked Gmail Compose.");
      await page.waitForTimeout(800);
      return;
    } catch {
      // Try the next Gmail variant.
    }
  }

  throw new Error("Could not find Gmail Compose.");
}

async function fillGmailDraft(page, parsed, steps) {
  await fillFirst(page, [
    'textarea[name="to"]',
    'input[name="to"]',
    'input[aria-label*="To"]',
    'textarea[aria-label*="To"]',
  ], parsed.recipient, "recipient");

  await page.keyboard.press("Enter").catch(() => {});
  steps.push(`Filled recipient ${parsed.recipient}.`);

  await fillFirst(page, [
    'input[name="subjectbox"]',
    'input[aria-label="Subject"]',
    'input[placeholder="Subject"]',
  ], parsed.subject, "subject");
  steps.push("Filled subject.");

  await fillFirst(page, [
    'div[aria-label="Message Body"]',
    'div[aria-label*="Message Body"]',
    'div[role="textbox"][contenteditable="true"]',
  ], parsed.body, "message body");
  steps.push("Filled message body.");
}

async function fillFirst(page, selectors, text, label) {
  for (const selector of selectors) {
    try {
      const locator = page.locator(selector).first();
      await locator.waitFor({ state: "visible", timeout: 5000 });
      await locator.fill(text);
      return;
    } catch {
      // Try the next selector.
    }
  }
  throw new Error(`Could not fill Gmail ${label}.`);
}

async function looksLikeLoginPage(page) {
  const url = page.url();
  if (/accounts\.google\.com|ServiceLogin|signin/i.test(url)) {
    return true;
  }
  const text = await page.locator("body").innerText({ timeout: 3000 }).catch(() => "");
  return /sign in|use your google account|email or phone/i.test(text) && !/compose/i.test(text);
}

async function waitForGmailLogin(page) {
  const deadline = Date.now() + 120_000;
  while (Date.now() < deadline) {
    if (!(await looksLikeLoginPage(page))) {
      return;
    }
    await page.waitForTimeout(1500);
  }
}

function isGmailTask(goal) {
  return /\bgmail\b|\bemail\b|\bcompose\b|\bdraft\b/i.test(goal);
}

function parseEmailDraft(goal) {
  const recipient = goal.match(/\b[\w.+-]+@[\w.-]+\.[a-z]{2,}\b/i)?.[0] || "";
  const subject = captureBetween(goal, /\bsubject(?:\s+is|:)?\s+/i, [/\bsaying\b/i, /\bthat says\b/i, /\bbody\b/i, /\bmessage\b/i]);
  const body = captureAfter(goal, [/\bsaying\s+/i, /\bthat says\s+/i, /\bbody(?:\s+is|:)?\s+/i, /\bmessage(?:\s+is|:)?\s+/i]);
  return {
    recipient: recipient.trim(),
    subject: cleanupField(subject),
    body: cleanupField(body),
  };
}

function captureBetween(text, startRegex, endRegexes) {
  const start = text.search(startRegex);
  if (start < 0) return "";
  const afterStart = text.slice(start).replace(startRegex, "");
  let end = afterStart.length;
  for (const regex of endRegexes) {
    const found = afterStart.search(regex);
    if (found >= 0) end = Math.min(end, found);
  }
  return afterStart.slice(0, end);
}

function captureAfter(text, regexes) {
  for (const regex of regexes) {
    const found = text.search(regex);
    if (found >= 0) return text.slice(found).replace(regex, "");
  }
  return "";
}

function cleanupField(value) {
  return String(value || "")
    .replace(/\s+and\s+stop\s+before\s+sending\.?$/i, "")
    .replace(/\s+but\s+do\s+not\s+send\.?$/i, "")
    .trim()
    .replace(/^["']|["']$/g, "");
}

function locatorFromArgs(page, args) {
  if (args.selector) return page.locator(args.selector);
  if (args.role) return page.getByRole(args.role, args.name ? { name: textMatcher(args.name, args.exact) } : {});
  if (args.text) return page.getByText(textMatcher(args.text, args.exact));
  if (args.name) return page.getByText(textMatcher(args.name, args.exact));
  throw new Error("browser_click needs role/name, text, or selector.");
}

function fillLocatorFromArgs(page, args) {
  if (args.selector) return page.locator(args.selector);
  if (args.label) return page.getByLabel(textMatcher(args.label, false));
  if (args.role) return page.getByRole(args.role, args.name ? { name: textMatcher(args.name, false) } : {});
  if (args.name) return page.getByLabel(textMatcher(args.name, false));
  throw new Error("browser_fill needs label, role/name, or selector.");
}

function textMatcher(value, exact) {
  if (exact) return value;
  return new RegExp(escapeRegExp(value), "i");
}

function guardHighImpact(label) {
  if (/\b(send|buy|purchase|delete|confirm|submit|pay|place order)\b/i.test(label)) {
    throw new Error(`Refusing high-impact click without explicit confirmation: ${label}`);
  }
}

async function pageSnapshot(page) {
  const title = await page.title().catch(() => "");
  const url = page.url();
  const bodyText = await page.locator("body").innerText({ timeout: 3000 }).catch(() => "");
  let aria = "";
  try {
    const body = page.locator("body");
    if (typeof body.ariaSnapshot === "function") {
      aria = await body.ariaSnapshot({ timeout: 3000 });
    }
  } catch {
    aria = "";
  }

  return {
    title,
    url,
    text: truncate(bodyText, MAX_TEXT),
    accessibility: truncate(aria, MAX_TEXT),
  };
}

async function saveScreenshot(page, userDataDir) {
  const dir = path.join(userDataDir, "screenshots");
  await fs.mkdir(dir, { recursive: true });
  const screenshotPath = path.join(dir, `browser-${Date.now()}.png`);
  await page.screenshot({ path: screenshotPath, fullPage: false });
  return screenshotPath;
}

function functionCalls(response) {
  return (response.output || []).filter((item) => item.type === "function_call");
}

function outputText(response) {
  if (response.output_text) return response.output_text;
  const chunks = [];
  for (const item of response.output || []) {
    for (const content of item.content || []) {
      if (content.text) chunks.push(content.text);
    }
  }
  return chunks.join("\n").trim();
}

function parseArguments(value) {
  if (!value) return {};
  if (typeof value === "object") return value;
  return JSON.parse(value);
}

async function readRequest() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const raw = Buffer.concat(chunks).toString("utf8").trim();
  return raw ? JSON.parse(raw) : {};
}

function browserUserDataDir() {
  if (process.env.BROWSER_USER_DATA_DIR) return process.env.BROWSER_USER_DATA_DIR;
  return path.join(os.homedir(), "Library", "Application Support", "ComputerControl", "ManagedChromium");
}

async function browserLaunchConfig(request) {
  const requestedMode = String(request.browserProfileMode || request.profileMode || "").trim();
  const useExistingChrome = requestedMode === "existing_chrome" || requestedMode === "chrome" || requestedMode === "existing";

  if (!useExistingChrome) {
    const userDataDir = browserUserDataDir();
    return {
      mode: "managed",
      userDataDir,
      channel: undefined,
      args: [],
      steps: [`Managed Chromium profile: ${userDataDir}`],
    };
  }

  const chromeRoot = chromeUserDataRoot();
  const profile = await resolveChromeProfile(request.browserProfile || request.profile || "");
  return {
    mode: "existing_chrome",
    userDataDir: chromeRoot,
    channel: "chrome",
    args: [`--profile-directory=${profile.directory}`],
    profile,
    steps: [
      `Existing Chrome user data: ${chromeRoot}`,
      `Existing Chrome profile: ${profile.displayName} (${profile.directory})`,
    ],
  };
}

function chromeUserDataRoot() {
  return process.env.CHROME_USER_DATA_DIR || path.join(os.homedir(), "Library", "Application Support", "Google", "Chrome");
}

function browserContextLabel(launchConfig) {
  if (launchConfig?.mode === "existing_chrome") {
    const profileName = launchConfig.profile?.displayName || launchConfig.profile?.directory || "selected";
    return `Chrome profile ${profileName}`;
  }
  return "managed Chromium";
}

async function resolveChromeProfile(profileHint) {
  const chromeRoot = chromeUserDataRoot();
  const profiles = await listChromeProfiles(chromeRoot);
  if (profiles.length === 0) {
    throw new Error(`No Chrome profiles were found in ${chromeRoot}.`);
  }

  const hint = String(profileHint || "").trim();
  if (hint) {
    const normalizedHint = normalizeProfileName(hint);
    const match = profiles.find((profile) =>
      normalizeProfileName(profile.directory) === normalizedHint ||
      normalizeProfileName(profile.displayName) === normalizedHint ||
      normalizeProfileName(profile.directory).includes(normalizedHint) ||
      normalizeProfileName(profile.displayName).includes(normalizedHint)
    );
    if (!match) {
      throw new Error(`Could not find Chrome profile "${hint}". Available profiles: ${profiles.map((profile) => `${profile.displayName} (${profile.directory})`).join(", ")}.`);
    }
    return match;
  }

  const localState = await readChromeLocalState(chromeRoot);
  const lastUsed = localState?.profile?.last_used;
  if (lastUsed) {
    const lastUsedMatch = profiles.find((profile) => profile.directory === lastUsed);
    if (lastUsedMatch) return lastUsedMatch;
  }

  const defaultProfile = profiles.find((profile) => profile.directory === "Default");
  return defaultProfile || profiles[0];
}

async function listChromeProfiles(chromeRoot) {
  const localState = await readChromeLocalState(chromeRoot);
  const infoCache = localState?.profile?.info_cache || {};
  const entries = await fs.readdir(chromeRoot, { withFileTypes: true }).catch(() => []);
  const profiles = [];

  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const directory = entry.name;
    const preferencesPath = path.join(chromeRoot, directory, "Preferences");
    try {
      await fs.access(preferencesPath);
    } catch {
      continue;
    }

    const info = infoCache[directory] || {};
    profiles.push({
      directory,
      displayName: info.name || directory,
      lastUsed: localState?.profile?.last_used === directory,
    });
  }

  profiles.sort((a, b) => {
    if (a.lastUsed !== b.lastUsed) return a.lastUsed ? -1 : 1;
    if (a.directory === "Default") return -1;
    if (b.directory === "Default") return 1;
    return a.directory.localeCompare(b.directory, undefined, { numeric: true });
  });

  return profiles;
}

async function readChromeLocalState(chromeRoot) {
  try {
    const raw = await fs.readFile(path.join(chromeRoot, "Local State"), "utf8");
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function normalizeProfileName(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function browserLaunchErrorMessage(error, launchConfig) {
  const message = errorMessage(error);
  if (launchConfig?.mode === "existing_chrome" && /singleton|processsingleton|already in use|profile.*use|user data directory.*use|failed to create.*lock/i.test(message)) {
    return `Chrome blocked automation from using profile ${launchConfig.profile?.displayName || ""} (${launchConfig.profile?.directory || ""}) because that profile is already open. Close regular Chrome and try again, or start Chrome with remote debugging if you want live-profile attachment. Original error: ${message}`;
  }
  return message;
}

function normalizeURL(url) {
  const trimmed = String(url || "").trim();
  if (!trimmed) throw new Error("URL is required.");
  return /^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;
}

function okResult({ spokenText, detail, steps, finalURL, screenshotPath }) {
  return {
    ok: true,
    spokenText,
    detail,
    steps: steps || [],
    finalURL: finalURL || "",
    screenshotPath: screenshotPath || null,
  };
}

function blockedResult(spokenText, detail, steps = [], finalURL = "") {
  return {
    ok: false,
    spokenText,
    detail,
    steps,
    finalURL,
    screenshotPath: null,
  };
}

function writeResult(result) {
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

function clampInt(value, min, max, fallback) {
  const number = Number.parseInt(value, 10);
  if (!Number.isFinite(number)) return fallback;
  return Math.max(min, Math.min(max, number));
}

function truncate(value, maxLength) {
  const string = String(value || "");
  return string.length > maxLength ? `${string.slice(0, maxLength)}...` : string;
}

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function joinHuman(items) {
  if (items.length <= 1) return items[0] || "";
  if (items.length === 2) return `${items[0]} and ${items[1]}`;
  return `${items.slice(0, -1).join(", ")}, and ${items.at(-1)}`;
}

function errorMessage(error) {
  if (!error) return "Unknown error.";
  return error instanceof Error ? error.message : String(error);
}

main().catch((error) => {
  writeResult(blockedResult("Browser automation crashed.", errorMessage(error)));
  process.exitCode = 1;
});
