document.getElementById("connect")?.addEventListener("click", async () => {
  await chrome.runtime.sendMessage({ type: "wake" });
  window.close();
});
