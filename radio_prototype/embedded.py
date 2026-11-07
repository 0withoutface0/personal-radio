"""Private engine lifecycle for a Flutter-owned installation."""

import json
import secrets
import socket
import sys
import threading
import time
from pathlib import Path

import uvicorn

from .api import create_app
from .config import Settings


class Engine:
    def __init__(self, data, *, providers=None, vault=None):
        self.token = secrets.token_urlsafe(32)
        self.socket = socket.socket()
        try:
            self.socket.bind(("127.0.0.1", 0))
            self.origin = f"http://127.0.0.1:{self.socket.getsockname()[1]}"
            settings = Settings(Path(data), local_setup=False)
            if providers is None and vault is not None:
                from .local_accounts import LocalProviders

                providers = LocalProviders(settings, vault)
            self.app = create_app(settings, providers, runtime_token=self.token, embedded=True)
            self.server = uvicorn.Server(
                uvicorn.Config(
                    self.app,
                    loop="asyncio",
                    http="h11",
                    ws="none",
                    lifespan="off",
                    proxy_headers=False,
                    access_log=False,
                    log_config=None,
                    timeout_graceful_shutdown=3,
                )
            )
            self.thread = threading.Thread(
                target=self.server.run, kwargs={"sockets": [self.socket]}, daemon=True
            )
        except BaseException:
            self.socket.close()
            raise

    def start(self):
        self.thread.start()
        deadline = time.monotonic() + 10
        while self.thread.is_alive() and not self.server.started and time.monotonic() < deadline:
            time.sleep(0.02)
        if not self.server.started:
            self.stop()
            raise RuntimeError("Local engine could not start")
        return {"origin": self.origin, "token": self.token}

    def stop(self):
        self.server.should_exit = True
        self.thread.join(5)
        if self.thread.is_alive():
            raise RuntimeError("Local engine is still stopping")
        self.socket.close()


_android_engine = None


def start_android(data, storage):
    global _android_engine
    from .vault import Vault

    if _android_engine is None or not _android_engine.thread.is_alive():
        engine = Engine(data, vault=Vault(Path(data), storage.seal, storage.open))
        result = engine.start()
        _android_engine = engine
    else:
        result = {"origin": _android_engine.origin, "token": _android_engine.token}
    return json.dumps(result)


def stop_android():
    global _android_engine
    if _android_engine is not None:
        _android_engine.stop()
        _android_engine = None


def run_windows():
    from .vault import windows_vault

    engine = None
    try:
        # Startup information and the runtime token use inherited pipes.
        config = json.loads(sys.stdin.readline())
        data = Path(config["data"]).resolve()
        engine = Engine(data, vault=windows_vault(data))
        print(json.dumps(engine.start()), flush=True)
        sys.stdin.readline()  # shutdown request, or EOF when the app exits
    except Exception:
        print('{"error":"Local engine could not start or stopped unexpectedly."}', flush=True)
        return 1
    finally:
        if engine is not None:
            engine.stop()
    return 0
