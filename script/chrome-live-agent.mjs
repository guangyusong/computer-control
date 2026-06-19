#!/usr/bin/env node
import express from "express";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import OpenAI from "openai";

const PORT = Number(process.env.CHROME_LIVE_BRIDGE_PORT || 38433);
const MAX_TEXT = 8000;
const EXTENSION_DIR = path.resolve("chrome-extension");

let lastExtensionSeen = 0;
let lastExtensionState = {};
let pendingCommands = [];
let pendingResults = new Map();

async function main() {
  if (process.argv.includes("--self-test")) {
    runSelfTest();
    return;
  }

  const server = await startBridge();
  try {
    if (process.argv.includes("--status")) {
      const result = await statusCheck();
      writeResult(result);
      return;
    }

    const request = await readRequest();
    const goal = String(request.text || request.goal || "").trim();
    if (!goal) {
      writeResult(blockedResult("I need a live Chrome task.", "Live Chrome request did not include text."));
      return;
    }

    const connected = await waitForExtension(6000);
    if (!connected) {
      writeResult(extensionMissingResult());
      return;
    }

    const result = isGmailTask(goal)
      ? await runLiveGmailTask({ goal, url: request.url })
      : await runModelChromeTask({
          goal,
          url: request.url,
          maxSteps: clampInt(request.maxSteps, 1, 30, 12),
        });
    writeResult(result);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

async function startBridge() {
  const app = express();
  app.use(express.json({ limit: "20mb" }));
  app.use((req, res, next) => {
    if (req.method === "OPTIONS") return res.sendStatus(204);
    next();
  });

  app.get("/health", (req, res) => {
    res.json({ ok: true, connected: isExtensionConnected(), lastExtensionSeen });
  });

  app.post("/extension/poll", (req, res) => {
    lastExtensionSeen = Date.now();
    lastExtensionState = req.body || {};
    const command = pendingCommands.shift() || null;
    res.json({ ok: true, command, waitMs: command ? 0 : 350 });
  });

  app.post("/extension/result", (req, res) => {
    const result = req.body || {};
    const waiter = pendingResults.get(result.id);
    if (waiter) {
      pendingResults.delete(result.id);
      waiter(result);
    }
    res.json({ ok: true });
  });

  return await new Promise((resolve, reject) => {
    const server = app.listen(PORT, "127.0.0.1", () => resolve(server));
    server.on("error", reject);
  });
}

async function statusCheck() {
  const connected = await waitForExtension(3000);
  if (!connected) return extensionMissingResult();

  const tabs = await sendCommand("chrome_open_tabs", {}, 3000).catch(() => null);
  const count = Array.isArray(tabs?.tabs) ? tabs.tabs.length : 0;
  return okResult({
    spokenText: "Live Chrome is connected.",
    detail: `Chrome extension connected. ${count} open tab${count === 1 ? "" : "s"} visible to the bridge.`,
    steps: ["Live Chrome extension polled the bridge.", `Open tabs detected: ${count}.`],
  });
}

async function runLiveGmailTask({ goal }) {
  const steps = ["Live Chrome extension connected."];
  const parsed = parseEmailDraft(goal);
  const justCompose = /\b(click|open|show)\b.*\bcompose\b/i.test(goal) && !/\b(draft|write|compose an email|compose email)\b/i.test(goal);

  await ensureGmailTab(steps);
  await sleep(1000);

  const loginSnapshot = await sendCommand("chrome_snapshot", {}, 5000);
  if (looksLikeLoginPage(loginSnapshot)) {
    return blockedResult(
      "Gmail needs you to log in first.",
      "Live Chrome is connected, but Gmail appears to be on a sign-in page. I stopped before guessing or entering credentials.",
      steps,
      loginSnapshot.url || ""
    );
  }

  const clicked = await clickCompose(steps);
  if (!clicked.ok) {
    return blockedResult(
      "I could not find Gmail Compose.",
      clicked.error || "Live Chrome could not click the Compose control.",
      steps,
      loginSnapshot.url || ""
    );
  }

  if (justCompose) {
    const snapshot = await sendCommand("chrome_snapshot", {}, 5000).catch(() => loginSnapshot);
    return okResult({
      spokenText: "Opened Gmail compose.",
      detail: "Gmail compose is open in live Chrome.",
      steps,
      finalURL: snapshot.url || loginSnapshot.url || "",
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
      loginSnapshot.url || ""
    );
  }

  await fillGmailDraft(parsed, steps);
  const finalSnapshot = await sendCommand("chrome_snapshot", {}, 5000).catch(() => loginSnapshot);
  return okResult({
    spokenText: "Drafted the email and stopped before sending.",
    detail: `Drafted to ${parsed.recipient} with subject "${parsed.subject}". Send was not clicked.`,
    steps,
    finalURL: finalSnapshot.url || loginSnapshot.url || "",
  });
}

async function ensureGmailTab(steps) {
  const openTabs = await sendCommand("chrome_open_tabs", {}, 5000);
  const tabs = openTabs.tabs || [];
  const gmail = tabs.find((tab) => /mail\.google\.com/i.test(tab.url || ""));
  if (gmail) {
    await sendCommand("chrome_claim_tab", { tabId: gmail.id }, 5000);
    steps.push(`Claimed existing Gmail tab: ${gmail.title || gmail.url}.`);
    return;
  }

  await sendCommand("chrome_navigate", { url: "https://mail.google.com/mail/u/0/#inbox" }, 8000);
  steps.push("Opened Gmail in live Chrome.");
}

async function clickCompose(steps) {
  const attempts = [
    { role: "button", name: "Compose", exact: false },
    { text: "Compose", exact: false },
    { selector: '[gh="cm"]' },
    { selector: '[aria-label*="Compose"]' },
  ];
  for (const args of attempts) {
    const result = await sendCommand("chrome_click", args, 5000).catch((error) => ({ ok: false, error: error.message }));
    if (result.ok) {
      steps.push("Clicked Gmail Compose.");
      await sleep(800);
      return result;
    }
  }
  return { ok: false, error: "No Compose selector matched." };
}

async function fillGmailDraft(parsed, steps) {
  await sendCommand("chrome_fill", {
    selector: 'textarea[name="to"], input[name="to"], input[aria-label*="To"], textarea[aria-label*="To"]',
    text: parsed.recipient,
  }, 5000);
  await sendCommand("chrome_press", { key: "Enter" }, 3000).catch(() => {});
  steps.push(`Filled recipient ${parsed.recipient}.`);

  await sendCommand("chrome_fill", {
    selector: 'input[name="subjectbox"], input[aria-label="Subject"], input[placeholder="Subject"]',
    text: parsed.subject,
  }, 5000);
  steps.push("Filled subject.");

  await sendCommand("chrome_fill", {
    selector: 'div[aria-label="Message Body"], div[aria-label*="Message Body"], div[role="textbox"][contenteditable="true"]',
    text: parsed.body,
  }, 5000);
  steps.push("Filled message body.");
}

async function runModelChromeTask({ goal, url, maxSteps }) {
  if (!process.env.OPENAI_API_KEY) {
    return blockedResult("I need an OpenAI API key before I can run live Chrome selection.", "OPENAI_API_KEY is missing.");
  }

  const steps = ["Live Chrome extension connected."];
  if (url) {
    const nav = await sendCommand("chrome_navigate", { url: normalizeURL(url) }, 8000);
    steps.push(`Navigated to ${nav.url || url}.`);
  }

  const client = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
  const model = process.env.BROWSER_AGENT_MODEL || "gpt-5.5";
  const tools = chromeTools();
  let response = await client.responses.create({
    model,
    store: false,
    input: [
      { role: "system", content: [{ type: "input_text", text: chromeInstructions() }] },
      { role: "user", content: [{ type: "input_text", text: goal }] },
    ],
    tools,
  });

  for (let step = 0; step < maxSteps; step += 1) {
    const calls = functionCalls(response);
    if (calls.length === 0) {
      const finalSnapshot = await sendCommand("chrome_snapshot", {}, 5000).catch(() => ({}));
      return okResult({
        spokenText: "Finished the live Chrome task.",
        detail: outputText(response) || "Live Chrome task finished.",
        steps,
        finalURL: finalSnapshot.url || "",
      });
    }

    const outputs = [];
    for (const call of calls) {
      const output = await executeChromeTool(call, steps);
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

  const finalSnapshot = await sendCommand("chrome_snapshot", {}, 5000).catch(() => ({}));
  return blockedResult("I stopped after the live Chrome step limit.", `Reached ${maxSteps} live Chrome steps.`, steps, finalSnapshot.url || "");
}

async function executeChromeTool(call, steps) {
  const args = parseArguments(call.arguments);
  try {
    switch (call.name) {
    case "chrome_open_tabs": {
      const result = await sendCommand("chrome_open_tabs", {}, 5000);
      steps.push(`Read ${result.tabs?.length || 0} open Chrome tabs.`);
      return { ok: true, tabs: result.tabs || [] };
    }
    case "chrome_claim_tab": {
      const result = await sendCommand("chrome_claim_tab", args, 5000);
      steps.push(`Claimed Chrome tab ${args.tabId}.`);
      return { ok: true, ...result };
    }
    case "chrome_navigate": {
      const result = await sendCommand("chrome_navigate", { url: normalizeURL(args.url) }, 8000);
      steps.push(`Navigated to ${result.url || args.url}.`);
      return { ok: true, ...result };
    }
    case "chrome_snapshot": {
      const result = await sendCommand("chrome_snapshot", {}, 5000);
      steps.push("Read live Chrome snapshot.");
      return { ok: true, ...truncateSnapshot(result) };
    }
    case "chrome_click": {
      guardHighImpact(args.name || args.text || args.selector || "");
      const result = await sendCommand("chrome_click", args, 5000);
      steps.push(`Clicked ${args.name || args.text || args.selector || args.role || "element"}.`);
      return { ok: true, ...result };
    }
    case "chrome_fill": {
      const result = await sendCommand("chrome_fill", args, 5000);
      steps.push(`Filled ${args.label || args.name || args.selector || "field"}.`);
      return { ok: true, ...result };
    }
    case "chrome_press": {
      const result = await sendCommand("chrome_press", args, 5000);
      steps.push(`Pressed ${args.key}.`);
      return { ok: true, ...result };
    }
    case "chrome_screenshot": {
      const result = await sendCommand("chrome_screenshot", {}, 8000);
      const screenshotPath = await saveDataURLScreenshot(result.dataUrl);
      steps.push(`Captured Chrome screenshot ${screenshotPath}.`);
      return { ok: true, screenshotPath };
    }
    case "chrome_finalize": {
      const result = await sendCommand("chrome_finalize", args, 5000);
      steps.push("Released live Chrome control.");
      return { ok: true, ...result };
    }
    default:
      return { ok: false, error: `Unsupported tool ${call.name}` };
    }
  } catch (error) {
    return { ok: false, error: errorMessage(error) };
  }
}

function chromeTools() {
  return [
    tool("chrome_open_tabs", "List open Chrome tabs by id, title, url, active state, and window id.", {}, []),
    tool("chrome_claim_tab", "Claim an open Chrome tab by tabId returned by chrome_open_tabs.", { tabId: { type: "integer" } }, ["tabId"]),
    tool("chrome_navigate", "Navigate the claimed tab, or open a new tab if none is claimed.", { url: { type: "string" } }, ["url"]),
    tool("chrome_snapshot", "Return text and interactive element snapshot for the claimed/current tab.", {}, []),
    tool("chrome_click", "Click an element in the claimed tab by role/name/text/CSS selector.", {
      role: { type: ["string", "null"] },
      name: { type: ["string", "null"] },
      text: { type: ["string", "null"] },
      selector: { type: ["string", "null"] },
      exact: { type: "boolean" },
    }, ["role", "name", "text", "selector", "exact"]),
    tool("chrome_fill", "Fill an input or editable field in the claimed tab.", {
      label: { type: ["string", "null"] },
      role: { type: ["string", "null"] },
      name: { type: ["string", "null"] },
      selector: { type: ["string", "null"] },
      text: { type: "string" },
    }, ["label", "role", "name", "selector", "text"]),
    tool("chrome_press", "Press a key in the claimed tab, such as Enter or Escape.", { key: { type: "string" } }, ["key"]),
    tool("chrome_screenshot", "Capture a visible-tab screenshot from Chrome.", {}, []),
    tool("chrome_finalize", "Release live Chrome control for the claimed tab.", { keep: { type: "boolean" } }, ["keep"]),
  ];
}

function tool(name, description, properties, required) {
  return {
    type: "function",
    name,
    description,
    parameters: {
      type: "object",
      additionalProperties: false,
      properties,
      required,
    },
  };
}

function chromeInstructions() {
  return `
You control the user's already-running Chrome through a constrained extension bridge.
Prefer chrome_snapshot before choosing selectors unless the next action is obvious.
Do not inspect cookies, local storage, passwords, or session stores.
Never click Send, Buy, Delete, Confirm, Submit, or other high-impact controls. Stop and ask for confirmation instead.
For Gmail, you may open compose and fill a draft, but never send it.
If login, CAPTCHA, permissions, or missing information blocks the task, explain what the user must do next.
Return a concise final answer with what changed and what is pending.
`;
}

async function sendCommand(type, payload = {}, timeoutMs = 5000) {
  const id = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
  const command = { id, type, payload };
  pendingCommands.push(command);

  return await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      pendingResults.delete(id);
      reject(new Error(`Timed out waiting for ${type}. Is the Chrome extension awake?`));
    }, timeoutMs);

    pendingResults.set(id, (result) => {
      clearTimeout(timeout);
      if (result.ok) {
        resolve(result.data || {});
      } else {
        reject(new Error(result.error || `${type} failed.`));
      }
    });
  });
}

async function waitForExtension(timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (isExtensionConnected()) return true;
    await sleep(150);
  }
  return isExtensionConnected();
}

function isExtensionConnected() {
  return Date.now() - lastExtensionSeen < 1500;
}

function extensionMissingResult() {
  return blockedResult(
    "Live Chrome needs the companion extension.",
    `Install or reload the unpacked extension from ${EXTENSION_DIR}, then press Demo Check. I did not open a managed fallback browser automatically.`,
    [
      `Bridge listening on http://127.0.0.1:${PORT}.`,
      `Expected extension directory: ${EXTENSION_DIR}.`,
      lastExtensionState?.version ? `Last extension version: ${lastExtensionState.version}.` : "No extension poll received.",
    ]
  );
}

function looksLikeLoginPage(snapshot) {
  const url = snapshot.url || "";
  if (/accounts\.google\.com|ServiceLogin|signin/i.test(url)) return true;
  const text = `${snapshot.text || ""} ${snapshot.accessibility || ""}`;
  return /sign in|use your google account|email or phone/i.test(text) && !/compose/i.test(text);
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

function guardHighImpact(label) {
  if (isHighImpactText(label)) {
    throw new Error(`High-impact action needs explicit confirmation first: ${label}`);
  }
}

function isHighImpactText(label) {
  return /\b(send|buy|delete|confirm|submit|purchase|pay|checkout|share|upload|post|publish|password|login|authenticate)\b/i.test(label);
}

async function saveDataURLScreenshot(dataUrl) {
  if (!dataUrl) throw new Error("Chrome did not return screenshot data.");
  const base64 = dataUrl.replace(/^data:image\/png;base64,/, "");
  const dir = path.join(os.tmpdir(), "ComputerControl", "LiveChromeScreenshots");
  await fs.mkdir(dir, { recursive: true });
  const screenshotPath = path.join(dir, `chrome-${Date.now()}.png`);
  await fs.writeFile(screenshotPath, Buffer.from(base64, "base64"));
  return screenshotPath;
}

function truncateSnapshot(snapshot) {
  return {
    ...snapshot,
    text: truncate(snapshot.text || "", MAX_TEXT),
    accessibility: truncate(snapshot.accessibility || "", MAX_TEXT),
  };
}

async function readRequest() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const raw = Buffer.concat(chunks).toString("utf8").trim();
  return raw ? JSON.parse(raw) : {};
}

function writeResult(result) {
  process.stdout.write(`${JSON.stringify(result)}\n`);
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

function functionCalls(response) {
  return (response.output || []).filter((item) => item.type === "function_call");
}

function outputText(response) {
  const pieces = [];
  for (const item of response.output || []) {
    if (item.type === "message") {
      for (const content of item.content || []) {
        if (content.type === "output_text" || content.type === "text") pieces.push(content.text);
      }
    }
  }
  return pieces.join("\n").trim();
}

function parseArguments(value) {
  if (!value) return {};
  if (typeof value === "object") return value;
  return JSON.parse(value);
}

function normalizeURL(url) {
  const trimmed = String(url || "").trim();
  if (!trimmed) throw new Error("URL is required.");
  return /^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;
}

function joinHuman(values) {
  if (values.length <= 1) return values[0] || "";
  if (values.length === 2) return `${values[0]} and ${values[1]}`;
  return `${values.slice(0, -1).join(", ")}, and ${values.at(-1)}`;
}

function truncate(value, max) {
  const text = String(value || "");
  return text.length > max ? `${text.slice(0, max)}...` : text;
}

function clampInt(value, min, max, fallback) {
  const number = Number.parseInt(value, 10);
  if (!Number.isFinite(number)) return fallback;
  return Math.min(max, Math.max(min, number));
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function errorMessage(error) {
  return error?.message || String(error);
}

function runSelfTest() {
  const parsed = parseEmailDraft("draft an email to alex@example.com with subject Hello saying It works");
  assert(parsed.recipient === "alex@example.com", "recipient parse failed");
  assert(parsed.subject === "Hello", "subject parse failed");
  assert(parsed.body === "It works", "body parse failed");
  assert(normalizeURL("example.com") === "https://example.com", "URL normalization failed");
  assert(isHighImpactText("click Send"), "high-impact detection failed");

  let blocked = false;
  try {
    guardHighImpact("Submit payment");
  } catch {
    blocked = true;
  }
  assert(blocked, "high-impact guard failed");

  writeResult(okResult({
    spokenText: "Live Chrome self-test passed.",
    detail: "Parser, URL normalization, and high-impact guard checks passed.",
    steps: ["Parsed Gmail draft.", "Normalized URL.", "Blocked high-impact action."],
  }));
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

main().catch((error) => {
  writeResult(blockedResult("Live Chrome automation failed.", errorMessage(error)));
  process.exitCode = 0;
});
