const status = document.querySelector("#status");
const connect = document.querySelector("#connect");
const cancel = document.querySelector("#cancel");

async function send(kind) {
  connect.disabled = true;
  try {
    const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
    status.textContent = await browser.runtime.sendMessage({ kind, tabId: tab?.id, url: tab?.url });
  } catch {
    status.textContent = "Open a new setup page from Personal Radio and try again.";
  } finally {
    connect.disabled = false;
  }
}

connect.onclick = () => send("start");
cancel.onclick = () => send("cancel");
browser.runtime.sendMessage({ kind: "status" }).then((message) => {
  status.textContent = message;
});
