const connectButton = document.querySelector("#connectButton");
const openExternalButton = document.querySelector("#openExternalButton");
const disconnectButton = document.querySelector("#disconnectButton");
const sendButton = document.querySelector("#sendButton");
const textCommand = document.querySelector("#textCommand");
const statusEl = document.querySelector("#status");
const transcriptEl = document.querySelector("#transcript");
const actionLogEl = document.querySelector("#actionLog");

let peerConnection;
let dataChannel;
let localStream;
let remoteAudio;
const handledToolCalls = new Set();
const partialArgsByCallId = new Map();

function setStatus(text) {
  statusEl.textContent = text;
}

function setVoiceControlsConnected(connected) {
  connectButton.disabled = connected;
  disconnectButton.disabled = !connected;
}

function addEntry(container, title, text, level = "") {
  const entry = document.createElement("div");
  entry.className = `entry ${level}`.trim();
  const strong = document.createElement("strong");
  strong.textContent = title;
  const body = document.createElement("div");
  body.textContent = text;
  entry.append(strong, body);
  container.prepend(entry);
}

function speakLocal(text) {
  if (!text || !("speechSynthesis" in window)) return;

  window.speechSynthesis.cancel();
  window.speechSynthesis.speak(new SpeechSynthesisUtterance(text));
}

function isPermissionDenied(error) {
  const text = `${error?.name || ""} ${error?.message || error || ""}`.toLowerCase();
  return text.includes("permission") || text.includes("notallowed") || text.includes("denied");
}

function sendRealtimeEvent(event) {
  if (!dataChannel || dataChannel.readyState !== "open") {
    addEntry(transcriptEl, "Client", "Realtime data channel is not open.", "warn");
    return;
  }

  dataChannel.send(JSON.stringify(event));
}

function assistantTextFromItem(item) {
  return (item.content || [])
    .filter((part) => part.type === "output_text" || part.type === "text")
    .map((part) => part.text || part.transcript || "")
    .join("");
}

function commandFromLegacyOpenArgs(args) {
  if (args.kind === "url") return `open ${args.target || ""}`.trim();
  if (args.kind === "app") return `open ${args.target || ""}`.trim();
  return String(args.target || args.command || "").trim();
}

async function runLocalCommand(command, { source = "Typed", speak = true } = {}) {
  addEntry(actionLogEl, source, command);

  let output;

  try {
    const response = await fetch("/command", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ command })
    });
    output = await response.json();

    if (output.ok) {
      addEntry(actionLogEl, "Done", output.spoken || `${output.action}: ${output.target}`, "ok");
      if (speak) speakLocal(output.spoken);
    } else {
      addEntry(actionLogEl, "Blocked", output.error || "Action was blocked.", "error");
      if (speak) speakLocal(output.error || "Action was blocked.");
    }
  } catch (error) {
    output = { ok: false, error: error instanceof Error ? error.message : String(error) };
    addEntry(actionLogEl, "Failed", output.error, "error");
    if (speak) speakLocal(output.error);
  }

  return output;
}

async function handleLocalCommandTool(item) {
  if (!item.call_id || handledToolCalls.has(item.call_id)) return;
  handledToolCalls.add(item.call_id);

  const rawArgs = item.arguments || partialArgsByCallId.get(item.call_id) || "{}";
  let args;

  try {
    args = JSON.parse(rawArgs);
  } catch {
    args = {};
  }

  const command = args.command || commandFromLegacyOpenArgs(args);
  const output = await runLocalCommand(command, { source: "Voice tool", speak: false });

  sendRealtimeEvent({
    type: "conversation.item.create",
    item: {
      type: "function_call_output",
      call_id: item.call_id,
      output: JSON.stringify(output)
    }
  });

  sendRealtimeEvent({ type: "response.create" });
}

function maybeHandleFunctionCall(item) {
  if (!item || item.type !== "function_call") return;
  if (item.name !== "run_local_command" && item.name !== "open_on_mac") return;
  void handleLocalCommandTool(item);
}

function handleRealtimeEvent(event) {
  switch (event.type) {
    case "session.created":
      addEntry(transcriptEl, "Realtime", "Session created.", "ok");
      break;
    case "session.updated":
      addEntry(transcriptEl, "Realtime", "Session updated.", "ok");
      break;
    case "input_audio_buffer.speech_started":
      setStatus("Listening");
      break;
    case "input_audio_buffer.speech_stopped":
      setStatus("Processing");
      break;
    case "conversation.item.input_audio_transcription.delta":
      break;
    case "response.audio_transcript.done":
    case "response.output_audio_transcript.done":
      if (event.transcript) addEntry(transcriptEl, "Assistant", event.transcript);
      break;
    case "conversation.item.input_audio_transcription.completed":
      if (event.transcript) addEntry(transcriptEl, "You", event.transcript);
      break;
    case "response.function_call_arguments.delta": {
      const current = partialArgsByCallId.get(event.call_id) || "";
      partialArgsByCallId.set(event.call_id, current + (event.delta || ""));
      break;
    }
    case "response.function_call_arguments.done":
      if (event.call_id && event.arguments) {
        partialArgsByCallId.set(event.call_id, event.arguments);
      }
      break;
    case "conversation.item.done":
    case "response.output_item.done": {
      const item = event.item;
      maybeHandleFunctionCall(item);

      if (item?.type === "message") {
        const text = assistantTextFromItem(item);
        if (text) addEntry(transcriptEl, item.role === "user" ? "You" : "Assistant", text);
      }
      break;
    }
    case "response.done":
      setStatus("Mic connected");
      break;
    case "error":
      addEntry(transcriptEl, "Realtime error", event.error?.message || JSON.stringify(event), "error");
      setStatus("Error");
      break;
    default:
      break;
  }
}

async function connect() {
  setVoiceControlsConnected(true);
  setStatus("Mic connecting");

  try {
    peerConnection = new RTCPeerConnection();

    remoteAudio = document.createElement("audio");
    remoteAudio.autoplay = true;
    peerConnection.ontrack = (event) => {
      remoteAudio.srcObject = event.streams[0];
    };

    localStream = await navigator.mediaDevices.getUserMedia({ audio: true });
    peerConnection.addTrack(localStream.getAudioTracks()[0]);

    dataChannel = peerConnection.createDataChannel("oai-events");
    dataChannel.addEventListener("open", () => {
      setStatus("Mic connected");
      setVoiceControlsConnected(true);
      addEntry(transcriptEl, "Client", "Connected.", "ok");
    });
    dataChannel.addEventListener("message", (message) => {
      try {
        handleRealtimeEvent(JSON.parse(message.data));
      } catch (error) {
        addEntry(transcriptEl, "Parse error", error instanceof Error ? error.message : String(error), "error");
      }
    });

    const offer = await peerConnection.createOffer();
    await peerConnection.setLocalDescription(offer);

    const response = await fetch("/session", {
      method: "POST",
      headers: { "Content-Type": "application/sdp" },
      body: offer.sdp
    });

    const answerSdp = await response.text();
    if (!response.ok) {
      throw new Error(answerSdp);
    }

    await peerConnection.setRemoteDescription({ type: "answer", sdp: answerSdp });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (isPermissionDenied(error)) {
      addEntry(
        transcriptEl,
        "Microphone blocked",
        "The Codex in-app browser denied microphone access. Open this page in Chrome or Safari to use voice.",
        "error"
      );
    } else {
      addEntry(transcriptEl, "Connection failed", message, "error");
    }
    disconnect();
  } finally {
    if (!dataChannel || dataChannel.readyState !== "open") {
      setVoiceControlsConnected(false);
    }
  }
}

function disconnect() {
  if (dataChannel) dataChannel.close();
  if (peerConnection) peerConnection.close();
  if (localStream) {
    for (const track of localStream.getTracks()) track.stop();
  }
  dataChannel = undefined;
  peerConnection = undefined;
  localStream = undefined;
  setVoiceControlsConnected(false);
  setStatus("Mic disconnected");
}

async function sendTextCommand() {
  const text = textCommand.value.trim();
  if (!text) return;

  addEntry(transcriptEl, "You", text);
  textCommand.value = "";
  await runLocalCommand(text, { source: "Typed", speak: true });
}

async function openInDefaultBrowser() {
  const url = window.location.href;
  try {
    const response = await fetch("/action/open", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        kind: "url",
        target: url,
        reason: "Open the voice control test in a browser with microphone access."
      })
    });
    const result = await response.json();
    if (result.ok) {
      addEntry(transcriptEl, "Opened", `Opened ${url} in your default browser.`, "ok");
    } else {
      addEntry(transcriptEl, "Open failed", result.error || "The local server blocked the action.", "error");
    }
  } catch (error) {
    addEntry(transcriptEl, "Open failed", error instanceof Error ? error.message : String(error), "error");
  }
}

connectButton.addEventListener("click", () => void connect());
openExternalButton.addEventListener("click", () => void openInDefaultBrowser());
disconnectButton.addEventListener("click", disconnect);
sendButton.addEventListener("click", () => void sendTextCommand());
textCommand.addEventListener("keydown", (event) => {
  if (event.key === "Enter") void sendTextCommand();
});

setVoiceControlsConnected(false);
sendButton.disabled = false;
void fetch("/health")
  .then((response) => response.json())
  .then((health) => {
    if (!health.hasApiKey) {
      addEntry(transcriptEl, "API key missing", "Add a local .openai file or OPENAI_API_KEY for voice.", "warn");
    }
  })
  .catch((error) => {
    addEntry(transcriptEl, "Server check failed", error instanceof Error ? error.message : String(error), "error");
  });
