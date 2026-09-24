// sidepanel.js — this site's chat, beside the page.
//
// One chat per site, in the editor's *browse* group. The panel names the
// page it sits beside; the editor finds or makes the chat, remembers the tab
// so the chat can go back to it, and answers the chat's name. The panel then
// shows that buffer as the editor draws it, through its buffer link.
// The panel belongs to the tab it was opened on. When that tab goes to
// another site, the panel shows that site's chat.

const frame = document.getElementById("chat");
const note = document.getElementById("note");
const tabId = Number(new URLSearchParams(location.search).get("tab")) || null;
let shown = null;

function say(text) {
  note.textContent = text;
  note.hidden = false;
  frame.hidden = true;
  shown = null;
}

async function follow() {
  try {
    await show();
  } catch (e) {
    say(`compos: ${(e && e.message) || e}`);
  }
}

async function show() {
  // a panel opened before it knew its tab follows the active one
  const tab = tabId
    ? await chrome.tabs.get(tabId)
    : (await chrome.tabs.query({ active: true, currentWindow: true }))[0];
  let host = "";
  try {
    const u = new URL(tab?.url || "");
    if (u.protocol === "http:" || u.protocol === "https:") host = u.host;
  } catch {}
  if (!host) return say("No chat for this page.");
  say(`Asking compos for the ${host} chat…`);

  const r = await chrome.runtime.sendMessage({
    cmd: "site-chat", host, tab: tab.id, url: tab.url, window: tab.windowId
  });
  if (!r?.ok) return say(`compos: ${r?.error || "no answer"}`);
  if (!r.result?.buffer) return say(`compos answered without a chat: ${JSON.stringify(r.result)}`);

  const src = `http://localhost:${r.result.port}/b/${encodeURIComponent(r.result.buffer)}`;
  if (src !== shown) {
    console.log("site chat", src);
    frame.src = src;
    shown = src;
  }
  note.hidden = true;
  frame.hidden = false;
}

chrome.tabs.onUpdated.addListener((id, change) => {
  if (id === tabId && change.url) follow();
});

follow();
