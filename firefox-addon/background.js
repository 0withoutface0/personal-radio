/* global browser */
const scope = { urls: ["https://music.youtube.com/youtubei/v1/browse*"] };
const allowed = new Set(["authorization", "cookie", "x-goog-authuser", "x-goog-pageid"]);
let active;
let status = "";

function setupEndpoint(text) {
  try {
    const url = new URL(text);
    if (url.protocol === "http:" && url.hostname === "127.0.0.1" &&
        url.port && url.pathname === "/connect-youtube" && !url.username &&
        !url.password && !url.search && /^#[A-Za-z0-9_-]{43}$/.test(url.hash)) {
      const nonce = url.hash.slice(1);
      url.hash = "";
      return { url: url.href, nonce };
    }
  } catch {
    // An ordinary tab may have no URL available to the add-on.
  }
  return null;
}

function setStatus(message, badge = "") {
  status = message;
  void browser.action.setBadgeText({ text: badge }).catch(() => {});
}

function stop(attempt, message, badge, abort = true) {
  if (active !== attempt) return;
  active = undefined;
  clearTimeout(attempt.timer);
  attempt.headers.clear();
  browser.webRequest.onBeforeSendHeaders.removeListener(capture);
  browser.webRequest.onCompleted.removeListener(complete);
  browser.webRequest.onErrorOccurred.removeListener(forget);
  if (abort) attempt.abort.abort();
  setStatus(message, badge);
}

function forget(details) {
  active?.headers.delete(details.requestId);
}

function capture(details) {
  const attempt = active;
  if (!attempt || attempt.sending || details.tabId !== attempt.musicTab ||
      details.method !== "POST" || new URL(details.url).pathname !== "/youtubei/v1/browse") return;
  const headers = Object.create(null);
  for (const header of details.requestHeaders ?? []) {
    const name = header.name.toLowerCase();
    if (allowed.has(name) && typeof header.value === "string") headers[name] = header.value;
  }
  if (!headers.authorization || !headers.cookie) return;
  if (attempt.headers.size >= 12) attempt.headers.delete(attempt.headers.keys().next().value);
  attempt.headers.set(details.requestId, headers);
}

async function complete(details) {
  const attempt = active;
  if (!attempt || attempt.sending || details.tabId !== attempt.musicTab) return;
  const headers = attempt.headers.get(details.requestId);
  attempt.headers.delete(details.requestId);
  if (!headers || details.statusCode < 200 || details.statusCode >= 300 ||
      new URL(details.url).pathname !== "/youtubei/v1/browse") return;
  attempt.sending = true;
  try {
    const response = await fetch(attempt.url, {
      method: "POST",
      headers: { Authorization: "Bearer " + attempt.nonce, "Content-Type": "application/json" },
      body: JSON.stringify({ text: JSON.stringify(headers) }),
      cache: "no-store",
      credentials: "omit",
      redirect: "error",
      signal: attempt.abort.signal,
    });
    if (!response.ok) throw new Error();
    stop(attempt, "Connected. Return to Personal Radio and choose Check accounts.", "OK", false);
  } catch {
    stop(attempt, "The session could not be verified. Open a fresh setup page in Personal Radio.", "!");
  }
}

async function start(message) {
  const endpoint = setupEndpoint(message.url);
  if (!endpoint) return "Open the setup page from Personal Radio before connecting.";
  if (active) return "A capture is already running. Cancel it before starting again.";
  const attempt = {
    ...endpoint, setupTab: message.tabId, headers: new Map(), abort: new AbortController(),
  };
  active = attempt;
  attempt.timer = setTimeout(() => stop(
    attempt, "Setup expired. Start again in Personal Radio.", "!",
  ), 300000);
  try {
    const page = await fetch(attempt.url, {
      credentials: "omit", redirect: "error", cache: "no-store", signal: attempt.abort.signal,
    });
    if (!page.ok || !(await page.text()).includes('name="personal-radio-connect" content="1"')) {
      throw new Error();
    }
    if (active !== attempt) return status;
    const tab = await browser.tabs.create({ url: "about:blank", active: false });
    if (active !== attempt) {
      await browser.tabs.remove(tab.id);
      return status;
    }
    attempt.musicTab = tab.id;
    browser.webRequest.onBeforeSendHeaders.addListener(capture, scope, ["requestHeaders"]);
    browser.webRequest.onCompleted.addListener(complete, scope);
    browser.webRequest.onErrorOccurred.addListener(forget, scope);
    setStatus("Sign in on the YouTube Music tab if prompted. Stay on that tab until setup finishes.", "...");
    await browser.tabs.update(tab.id, { url: "https://music.youtube.com/", active: true });
    return status;
  } catch {
    stop(attempt, "This setup page is unavailable. Start again in Personal Radio.", "!");
    return status;
  }
}

browser.tabs.onRemoved.addListener((tabId) => {
  if (active && (tabId === active.musicTab || tabId === active.setupTab)) {
    stop(active, "Capture cancelled.");
  }
});

browser.runtime.onMessage.addListener((message, sender) => {
  if (sender.url !== browser.runtime.getURL("connect.html")) return undefined;
  if (message.kind === "start") return start(message);
  if (message.kind === "cancel" && active) stop(active, "Capture cancelled.");
  return Promise.resolve(status);
});
