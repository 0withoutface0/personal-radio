"""Issue fresh YouTube Music browser credentials to an authorized radio device."""
import asyncio
import json
import secrets
import time
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from ytmusicapi.helpers import get_authorization, sapisid_from_cookie

from radio_prototype.local_accounts import LocalProviders

MUSIC = "https://music.youtube.com/"
CDP = "http://127.0.0.1:9222"


async def capture():
    from playwright.async_api import async_playwright

    async with async_playwright() as playwright:
        browser = await playwright.chromium.connect_over_cdp(CDP, timeout=5000)
        context = browser.contexts[0]
        # A fresh tab can receive a signed-out page even while the browser's
        # existing YouTube Music tab has a valid signed-in session.
        page = next((tab for tab in reversed(context.pages) if tab.url.startswith(MUSIC)), None)
        temporary = page is None
        if temporary:
            page = await context.new_page()
        try:
            if temporary:
                await page.goto(MUSIC, wait_until="domcontentloaded", timeout=10000)
            if not page.url.startswith(MUSIC):
                raise ValueError("YouTube Music requires sign-in or consent")
            await page.wait_for_function(
                '() => typeof globalThis.ytcfg?.get?.("LOGGED_IN") === "boolean"',
                timeout=6000,
            )
            config = await page.evaluate("""() => ({
                signedIn: globalThis.ytcfg?.get?.("LOGGED_IN"),
                account: globalThis.ytcfg?.get?.("SESSION_INDEX"),
                pageId: globalThis.ytcfg?.get?.("DELEGATED_SESSION_ID"),
            })""")
            if config.get("signedIn") is not True:
                raise ValueError("No signed-in account")
            # Home can be server-rendered without generating a browse request.
            # Build the same authorization from current cookies for the Music API.
            cookies = await context.cookies(MUSIC + "youtubei/v1/browse")
            cookie = "; ".join(f"{item['name']}={item['value']}" for item in cookies)
            authorization = get_authorization(sapisid_from_cookie(cookie) + " " + MUSIC[:-1])
            auth = {
                "cookie": cookie,
                "authorization": authorization,
                "x-goog-authuser": str(config.get("account") or 0),
            }
            if config.get("pageId"):
                auth["x-goog-pageid"] = str(config["pageId"])
            record, _ = await asyncio.to_thread(
                LocalProviders._verified_youtube, json.dumps(auth),
            )
            if not record["identity"]:
                raise ValueError("No verified channel")
            return record
        finally:
            if temporary:
                await page.close()


def create_app(*, capture_session=capture, token_path=Path("/state/device-token.txt")):
    token = token_path.read_text(encoding="utf-8").strip()
    if len(token) < 40:
        raise ValueError("Missing strong radio device token")
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    lock = asyncio.Lock()
    next_capture = 0
    record = None

    @app.get("/health")
    async def health():
        return {"service": "personal-radio-youtube-auth", "version": 1}

    @app.post("/v1/session")
    async def session(request: Request):
        nonlocal next_capture, record
        if not secrets.compare_digest(
            request.headers.get("authorization", "").encode(), ("Bearer " + token).encode(),
        ):
            raise HTTPException(401, "Invalid renewal token.")
        async with lock:
            # Coalesce multiple device requests and bound how often an
            # unavailable or signed-out browser gets opened.
            if time.monotonic() >= next_capture:
                try:
                    record = await capture_session()
                except Exception:
                    record = None
                finally:
                    next_capture = time.monotonic() + 20
            if not record:
                raise HTTPException(503, "Open the OMV browser and sign in to YouTube Music.")
            return JSONResponse(
                {"auth": record["auth"], "channel": record["identity"]},
                headers={"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"},
            )

    return app
