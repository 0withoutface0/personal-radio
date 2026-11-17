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


class SetupTidal(BaseModel):
    token_type: Literal["Bearer", "bearer"]
    access_token: str = Field(min_length=1, max_length=16_384)
    refresh_token: str = Field(min_length=1, max_length=16_384)
    is_pkce: Literal[True]


class SetupAccounts(BaseModel):
    youtube: dict[str, str] = Field(min_length=2, max_length=8)
    tidal: SetupTidal


class YouTubeRenewal(BaseModel):
    origin: str = Field(min_length=1, max_length=300)
    token: str = Field(min_length=1, max_length=128)


class ConfirmYouTubeRecovery(BaseModel):
    confirmation: str = Field(pattern=r"^[0-9a-f]{64}$")


def account_routes(providers, store, authorize):
    protected = [Depends(authorize)]
    router = APIRouter()
    pair = None
    lock = threading.Lock()

    @router.post("/api/local/accounts/youtube", dependencies=protected)
    def youtube(body: SetupText):
        providers.connect_youtube(body.text)
        return providers.status()["youtube"]

    @router.post("/api/local/accounts/youtube/check", dependencies=protected)
    def check_youtube():
        return providers.check_youtube()

    @router.put("/api/local/accounts/youtube/renewal", dependencies=protected)
    def configure_renewal(body: YouTubeRenewal):
        providers.connect_youtube_server(body.origin, body.token)
        return providers.status()["youtube"]

    @router.delete("/api/local/accounts/youtube/renewal", dependencies=protected)
    def stop_renewal():
        providers.stop_youtube_renewal()
        return providers.status()["youtube"]

    def verified_channel():
        channel = providers.identity("youtube")
        if not channel:
            raise HTTPException(409, "Check accounts to verify your YouTube Music channel first.")
        return channel

    @router.get("/api/local/accounts/youtube/recovery", dependencies=protected)
    def preview_recovery():
        with providers.lock:
            return {
                **store.youtube_recovery(verified_channel()),
                "label": providers.status()["youtube"]["label"],
            }

    @router.post("/api/local/accounts/youtube/recovery", dependencies=protected)
    def confirm_recovery(body: ConfirmYouTubeRecovery):
        with providers.lock:
            providers.check_youtube()
            result = store.youtube_recovery(verified_channel(), body.confirmation)
            if result is None:
                raise HTTPException(409, "The channel or pending activity changed. Review again.")
            return result

    @router.post("/api/local/accounts/youtube/transfer", dependencies=protected)
    def transfer():
        return providers.youtube_transfer()

    @router.post("/api/local/accounts/setup/transfer", dependencies=protected)
    def setup_transfer(response: Response):
        response.headers["Cache-Control"] = "no-store"
        return providers.setup_transfer()

    @router.post("/api/local/accounts/setup", dependencies=protected)
    def import_setup(body: SetupAccounts):
        providers.import_setup(body.youtube, body.tidal.model_dump())
        return providers.status()

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
