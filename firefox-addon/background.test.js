const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { runInNewContext } = require("node:vm");
const { test } = require("node:test");

test("captures a successful request only in the explicitly opened Music tab", async () => {
  const event = () => ({
    listener: undefined,
    addListener(listener) { this.listener = listener; },
    removeListener(listener) { if (this.listener === listener) this.listener = undefined; },
  });
  const runtime = { onMessage: event(), getURL: () => "mock-extension/connect.html" };
  const webRequest = { onBeforeSendHeaders: event(), onCompleted: event(), onErrorOccurred: event() };
  const calls = [];
  const browser = {
    action: { setBadgeText: async () => {} },
    runtime,
    webRequest,
    tabs: { create: async () => ({ id: 2 }), update: async () => {}, onRemoved: event() },
  };
  runInNewContext(readFileSync(require.resolve("./background.js"), "utf8"), {
    browser, URL, AbortController, setTimeout, clearTimeout,
    fetch: async (url, options) => {
      calls.push({ url, options });
      return { ok: true, text: async () => 'name="personal-radio-connect" content="1"' };
    },
  });
  const send = (kind, url) => runtime.onMessage.listener(
    { kind, url, tabId: 1 }, { url: runtime.getURL() },
  );
  const nonce = "a".repeat(43);
  await send("start", "https://example.com/connect-youtube#" + nonce);
  assert.equal(calls.length, 0);
  await send("start", "http://127.0.0.1:12345/connect-youtube#" + nonce);
  assert.equal(calls.length, 1);
  const request = {
    tabId: 2, method: "POST", requestId: "7",
    url: "https://music.youtube.com/youtubei/v1/browse",
    requestHeaders: [
      { name: "Cookie", value: "TEST_SESSION=fixture" },
      { name: "Authorization", value: "fixture" },
      { name: "User-Agent", value: "dropped" },
    ],
  };
  webRequest.onBeforeSendHeaders.listener({ ...request, tabId: 3 });
  await webRequest.onCompleted.listener({ ...request, statusCode: 200 });
  assert.equal(calls.length, 1);
  webRequest.onBeforeSendHeaders.listener(request);
  await webRequest.onCompleted.listener({ ...request, statusCode: 403 });
  assert.equal(calls.length, 1);
  webRequest.onBeforeSendHeaders.listener(request);
  await webRequest.onCompleted.listener({ ...request, statusCode: 200 });
  assert.equal(calls.length, 2);
  const { url, options } = calls[1];
  assert.equal(url, "http://127.0.0.1:12345/connect-youtube");
  assert.equal(options.redirect, "error");
  assert.equal(options.headers.Authorization, "Bearer " + nonce);
  assert.deepEqual(JSON.parse(JSON.parse(options.body).text), {
    cookie: "TEST_SESSION=fixture", authorization: "fixture",
  });
  assert.equal(webRequest.onBeforeSendHeaders.listener, undefined);
});
