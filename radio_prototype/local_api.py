"""Account setup routes exposed only by the embedded loopback engine."""

import secrets
import threading
import time
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field


class SetupText(BaseModel):
    text: str = Field(min_length=1, max_length=200_000)


def account_routes(providers, authorize):
    protected = [Depends(authorize)]
    router = APIRouter()
    pair = None
    lock = threading.Lock()

    @router.post("/api/local/accounts/youtube", dependencies=protected)
    def youtube(body: SetupText):
        providers.connect_youtube(body.text)
        return providers.status()["youtube"]

    @router.post("/api/local/accounts/youtube/transfer", dependencies=protected)
    def transfer():
        return providers.youtube_transfer()

    @router.post("/api/local/accounts/tidal/start", dependencies=protected)
    def tidal_start():
        return {"login_url": providers.start_pkce()}

    @router.post("/api/local/accounts/tidal/finish", dependencies=protected)
    def tidal_finish(body: SetupText):
        providers.finish_pkce(body.text)
        return providers.status()["tidal"]

    @router.delete("/api/local/accounts/tidal/attempt", dependencies=protected)
    def tidal_cancel():
        providers.cancel_pkce()
        return {"cancelled": True}

    @router.delete("/api/local/accounts/{provider}", dependencies=protected)
    def disconnect(provider: Literal["youtube", "tidal"]):
        providers.disconnect(provider)
        return {"disconnected": True}

    @router.post("/api/local/accounts/browser", dependencies=protected)
    def browser_start():
        nonlocal pair
        with lock:
            nonce = secrets.token_urlsafe(32)
            pair = (nonce, time.monotonic() + 300)
            return {"path": "/connect-youtube#" + nonce}

    @router.delete("/api/local/accounts/browser", dependencies=protected)
    def browser_cancel():
        nonlocal pair
        with lock:
            pair = None
        return {"cancelled": True}

    @router.get("/connect-youtube", response_class=HTMLResponse, include_in_schema=False)
    def browser_page():
        return (
            '<!doctype html><meta name="personal-radio-connect" content="1">'
            "<title>Connect Personal Radio</title><h1>Connect YouTube Music</h1>"
            "<p>Open the Personal Radio Connect add-on in Firefox and choose "
            "Connect. When it finishes, return to Personal Radio.</p>"
        )

    def browser_headers(request):
        origin = request.headers.get("origin")
        if origin is None:
            return {}
        if not origin.startswith("moz-extension://") or len(origin) > 80:
            raise HTTPException(403, "Open this setup page with the Firefox add-on.")
        return {
            "Access-Control-Allow-Origin": origin,
            "Access-Control-Allow-Methods": "POST",
            "Access-Control-Allow-Headers": "authorization, content-type",
            "Vary": "Origin",
        }

    @router.options("/connect-youtube", include_in_schema=False)
    def browser_options(request: Request):
        return Response(status_code=204, headers=browser_headers(request))

    @router.post("/connect-youtube", include_in_schema=False)
    def browser_finish(request: Request, response: Response, body: SetupText):
        nonlocal pair
        response.headers.update(browser_headers(request))
        presented = request.headers.get("authorization", "")
        with lock:
            if (
                pair is None
                or time.monotonic() >= pair[1]
                or not secrets.compare_digest(presented, "Bearer " + pair[0])
            ):
                raise HTTPException(401, "Start a new Firefox connection in Personal Radio.")
            pair = None
        providers.connect_youtube(body.text)
        return {"connected": True}

    return router
