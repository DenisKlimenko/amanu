// Relays the content script's speaker states to amanu.
//
// Only an extension's own pages may open a native-messaging port, so the
// content script cannot talk to amanu directly. The port also keeps this
// worker alive for as long as it is open; when the browser stops the worker
// anyway, the next message opens a new port, and amanu reads every file its
// host wrote.

const HOST = "me.samat.amanu.meet";
// After a failed connect — the host not installed, amanu moved — wait this
// long before trying again, rather than once per message.
const RETRY_AFTER_MS = 30_000;

let port = null;
let failedAt = 0;

function connect() {
  if (Date.now() - failedAt < RETRY_AFTER_MS) return null;
  const opened = chrome.runtime.connectNative(HOST);
  opened.onDisconnect.addListener(() => {
    if (chrome.runtime.lastError) {
      console.warn("amanu host:", chrome.runtime.lastError.message);
      failedAt = Date.now();
    }
    if (port === opened) port = null;
  });
  return opened;
}

chrome.runtime.onMessage.addListener((message) => {
  port = port ?? connect();
  if (!port) return;
  try {
    port.postMessage(message);
  } catch (error) {
    console.warn("amanu host:", error);
    port = null;
  }
});
