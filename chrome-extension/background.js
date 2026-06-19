const BRIDGE_URL = "http://127.0.0.1:38433";
const VERSION = "0.1.0";
const ALARM_NAME = "computer-control-live-chrome-poll";

let claimedTabId = null;
let polling = false;

chrome.runtime.onInstalled.addListener(() => {
  ensureAlarm();
  startPolling();
});

chrome.runtime.onStartup.addListener(() => {
  ensureAlarm();
  startPolling();
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type === "wake") {
    startPolling();
    sendResponse({ ok: true });
    return true;
  }
  return false;
});

chrome.action.onClicked?.addListener(() => {
  startPolling();
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === ALARM_NAME) startPolling();
});

ensureAlarm();
startPolling();

function ensureAlarm() {
  chrome.alarms.create(ALARM_NAME, { periodInMinutes: 0.5 });
}

function startPolling() {
  if (polling) return;
  polling = true;
  pollBridge();
}

async function pollBridge() {
  while (polling) {
    let waitMs = 700;
    try {
      const response = await fetch(`${BRIDGE_URL}/extension/poll`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          version: VERSION,
          claimedTabId,
          userAgent: navigator.userAgent,
        }),
      });
      const payload = await response.json();
      waitMs = payload.waitMs || 350;
      if (payload.command) {
        await handleCommand(payload.command);
        waitMs = 50;
      }
    } catch {
      waitMs = 1000;
    }
    await sleep(waitMs);
  }
}

async function handleCommand(command) {
  try {
    const data = await executeCommand(command.type, command.payload || {});
    await postResult({ id: command.id, ok: true, data });
  } catch (error) {
    await postResult({ id: command.id, ok: false, error: error?.message || String(error) });
  }
}

async function postResult(result) {
  await fetch(`${BRIDGE_URL}/extension/result`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(result),
  }).catch(() => {});
}

async function executeCommand(type, payload) {
  switch (type) {
  case "chrome_open_tabs":
    return { tabs: await openTabs() };
  case "chrome_claim_tab":
    return await claimTab(payload.tabId);
  case "chrome_navigate":
    return await navigate(payload.url);
  case "chrome_snapshot":
    return await snapshot();
  case "chrome_click":
    return await runInClaimedTab(clickElement, payload);
  case "chrome_fill":
    return await runInClaimedTab(fillElement, payload);
  case "chrome_press":
    return await runInClaimedTab(pressKey, payload);
  case "chrome_screenshot":
    return await screenshot();
  case "chrome_finalize":
    claimedTabId = null;
    return { ok: true };
  default:
    throw new Error(`Unsupported command ${type}`);
  }
}

async function openTabs() {
  const tabs = await chrome.tabs.query({});
  return tabs
    .filter((tab) => tab.id != null && !/^chrome:|^edge:|^about:/i.test(tab.url || ""))
    .map((tab) => ({
      id: tab.id,
      windowId: tab.windowId,
      active: tab.active,
      title: tab.title || "",
      url: tab.url || "",
    }));
}

async function claimTab(tabId) {
  const id = Number(tabId);
  if (!Number.isFinite(id)) throw new Error("chrome_claim_tab needs tabId.");
  const tab = await chrome.tabs.get(id);
  claimedTabId = id;
  await chrome.windows.update(tab.windowId, { focused: true }).catch(() => {});
  await chrome.tabs.update(id, { active: true });
  return tabSummary(await chrome.tabs.get(id));
}

async function navigate(url) {
  if (!url) throw new Error("chrome_navigate needs url.");
  let tab;
  if (claimedTabId != null) {
    tab = await chrome.tabs.update(claimedTabId, { url });
  } else {
    tab = await chrome.tabs.create({ url, active: true });
    claimedTabId = tab.id;
  }
  return tabSummary(tab);
}

async function snapshot() {
  const tab = await currentTab();
  const page = await runInTab(tab.id, collectSnapshot, {});
  return {
    ...tabSummary(tab),
    text: page.text,
    accessibility: page.accessibility,
  };
}

async function screenshot() {
  const tab = await currentTab();
  const dataUrl = await chrome.tabs.captureVisibleTab(tab.windowId, { format: "png" });
  return { dataUrl, ...tabSummary(tab) };
}

async function currentTab() {
  if (claimedTabId != null) {
    try {
      return await chrome.tabs.get(claimedTabId);
    } catch {
      claimedTabId = null;
    }
  }
  const [active] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!active?.id) throw new Error("No active Chrome tab is available.");
  claimedTabId = active.id;
  return active;
}

async function runInClaimedTab(func, payload) {
  const tab = await currentTab();
  return await runInTab(tab.id, func, payload);
}

async function runInTab(tabId, func, payload) {
  const [{ result }] = await chrome.scripting.executeScript({
    target: { tabId },
    func,
    args: [payload || {}],
  });
  if (result?.ok === false) throw new Error(result.error || "Page script failed.");
  return result || {};
}

function tabSummary(tab) {
  return {
    id: tab.id,
    windowId: tab.windowId,
    active: tab.active,
    title: tab.title || "",
    url: tab.url || "",
  };
}

function collectSnapshot() {
  const interactiveSelectors = [
    "button",
    "a",
    "input",
    "textarea",
    "select",
    "[role]",
    "[aria-label]",
    "[contenteditable='true']",
  ];
  const elements = Array.from(document.querySelectorAll(interactiveSelectors.join(","))).slice(0, 140);
  const accessibility = elements.map((element, index) => {
    const role = element.getAttribute("role") || element.tagName.toLowerCase();
    const name = (
      element.getAttribute("aria-label") ||
      element.getAttribute("placeholder") ||
      element.getAttribute("title") ||
      element.innerText ||
      element.value ||
      ""
    ).trim().replace(/\s+/g, " ").slice(0, 120);
    return `${index + 1}. role=${role} name="${name}" selector="${selectorFor(element)}"`;
  }).join("\n");

  return {
    ok: true,
    title: document.title,
    url: location.href,
    text: document.body?.innerText?.slice(0, 12000) || "",
    accessibility,
  };
}

function clickElement(args) {
  const element = findElement(args);
  if (!element) return { ok: false, error: "No matching element found." };
  element.scrollIntoView({ block: "center", inline: "center" });
  element.click();
  return { ok: true, url: location.href };
}

function fillElement(args) {
  const element = findElement(args);
  if (!element) return { ok: false, error: "No matching field found." };
  const text = String(args.text ?? "");
  element.scrollIntoView({ block: "center", inline: "center" });
  element.focus();
  if (element.isContentEditable) {
    element.textContent = text;
  } else {
    element.value = text;
  }
  element.dispatchEvent(new InputEvent("input", { inputType: "insertText", data: text, bubbles: true }));
  element.dispatchEvent(new Event("change", { bubbles: true }));
  return { ok: true };
}

function pressKey(args) {
  const key = String(args.key || "");
  const target = document.activeElement || document.body;
  for (const type of ["keydown", "keypress", "keyup"]) {
    target.dispatchEvent(new KeyboardEvent(type, { key, code: key, bubbles: true, cancelable: true }));
  }
  return { ok: true };
}

function findElement(args) {
  if (args.selector) {
    const selectors = String(args.selector).split(",").map((value) => value.trim()).filter(Boolean);
    for (const selector of selectors) {
      const element = document.querySelector(selector);
      if (element) return element;
    }
  }

  const query = normalize(args.name || args.text || args.label || "");
  const role = normalize(args.role || "");
  const exact = Boolean(args.exact);
  const candidates = Array.from(document.querySelectorAll("button,a,input,textarea,select,[role],[aria-label],[contenteditable='true']"));
  return candidates.find((element) => {
    const elementRole = normalize(element.getAttribute("role") || element.tagName);
    const elementName = normalize(
      element.getAttribute("aria-label") ||
      element.getAttribute("placeholder") ||
      element.getAttribute("title") ||
      element.innerText ||
      element.value ||
      ""
    );
    const roleMatches = !role || elementRole.includes(role);
    const nameMatches = !query || (exact ? elementName === query : elementName.includes(query));
    return roleMatches && nameMatches;
  });
}

function selectorFor(element) {
  if (element.id) return `#${cssEscape(element.id)}`;
  const attr = ["aria-label", "name", "placeholder", "role"].find((name) => element.getAttribute(name));
  if (attr) return `${element.tagName.toLowerCase()}[${attr}="${cssEscape(element.getAttribute(attr))}"]`;
  return element.tagName.toLowerCase();
}

function normalize(value) {
  return String(value || "").toLowerCase().replace(/\s+/g, " ").trim();
}

function cssEscape(value) {
  return String(value || "").replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
