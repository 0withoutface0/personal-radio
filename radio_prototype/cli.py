import argparse
import json
import shutil
import sys
import time
from pathlib import Path

import requests

from .config import Settings, private_write
from .playback import Client, Outbox, listen


def main():
    parser = argparse.ArgumentParser(description="Personal radio integration prototype")
    parser.add_argument("--url", default="http://127.0.0.1:8765")
    sub = parser.add_subparsers(dest="command", required=True)
    serve = sub.add_parser("serve", help="Start the local account setup and diagnostic API")
    serve.add_argument("--port", type=int, default=8765)
    serve.add_argument("--host", default="127.0.0.1", help="Loopback or this PC's Tailscale IP")
    auth = sub.add_parser("auth", help="Interactive authentication on the host; no secrets in chat")
    auth.add_argument("provider", choices=["youtube", "tidal"])
    for command in ("status", "stations", "flush", "reconcile", "replay-events"):
        sub.add_parser(command)
    report = sub.add_parser("report")
    report.add_argument("--output", type=Path)
    search = sub.add_parser("search")
    search.add_argument("query")
    radio = sub.add_parser("radio")
    radio.add_argument("--video-id")
    radio.add_argument("--playlist-id")
    autoplay = sub.add_parser("autoplay", help="Normal song playback with YouTube Autoplay")
    autoplay_source = autoplay.add_mutually_exclusive_group(required=True)
    autoplay_source.add_argument("--video-id")
    autoplay_source.add_argument(
        "--cursor", help="Continue the saved queue without starting a new mix"
    )
    autoplay.add_argument("--limit", type=int, default=None, help="Initial page size, 1 to 100")
    verify = sub.add_parser("verify", help="Decode a full source; never reports listening")
    verify.add_argument("tidal_id", type=int)
    verify.add_argument("--hires", action="store_true")
    player = sub.add_parser("listen", help="Audible mpv prototype with durable playback accounting")
    player.add_argument("--tidal-id", type=int)
    player.add_argument("--video-id")
    player.add_argument("--resume-occurrence")
    player.add_argument("--mpv", type=Path)
    player.add_argument(
        "--no-report", action="store_true", help="Keep activity local; no provider dispatch"
    )
    rating = sub.add_parser("rate")
    rating.add_argument("occurrence_id")
    rating.add_argument("value", choices=["LIKE", "DISLIKE", "INDIFFERENT"])
    args = parser.parse_args()
    settings = Settings.from_env()
    if args.command == "auth":
        if args.provider == "youtube":
            import ytmusicapi

            parsed = ytmusicapi.setup()
            private_write(settings.youtube_file, parsed)
        else:
            from .providers import Providers

            private_write(
                settings.tidal_file,
                settings.tidal_file.read_text(encoding="utf-8")
                if settings.tidal_file.exists()
                else "{}",
            )
            session = Providers.new_tidal()
            if not session.login_session_file(settings.tidal_file, do_pkce=True):
                raise SystemExit("Tidal login failed")
        print("Credentials saved locally. Restart the prototype after changing account files.")
        return
    if args.command == "serve":
        import ipaddress

        import uvicorn

        from .api import create_app

        try:
            address = ipaddress.ip_address(args.host)
        except ValueError:
            parser.error("--host must be a loopback or Tailscale IP address")
        if not address.is_loopback:
            if address not in ipaddress.ip_network("100.64.0.0/10"):
                parser.error("Bind to loopback or the PC's Tailscale IPv4 address")
            settings.local_setup = False
            import os

            os.environ["RADIO_ALLOWED_HOSTS"] = ",".join([*settings.allowed_hosts, args.host])
            os.environ["RADIO_INTERNAL_ORIGIN"] = f"http://{args.host}:{args.port}"
        if settings.local_setup:
            print(f"Local account setup: http://127.0.0.1:{args.port}")
        print(f"Device API token is stored in {settings.token_file}; do not share it.")
        uvicorn.run(
            create_app(settings),
            host=args.host,
            port=args.port,
            proxy_headers=False,
            access_log=False,
        )
        return
    client = Client(args.url, settings.device_token())
    try:
        if args.command == "status":
            result = client.call("/api/accounts", method="GET")
        elif args.command == "search":
            from urllib.parse import urlencode

            result = client.call("/api/search?" + urlencode({"q": args.query}), method="GET")
        elif args.command == "stations":
            result = client.call("/api/stations", method="GET")
        elif args.command == "radio":
            result = client.call(
                "/api/radio", {"video_id": args.video_id, "playlist_id": args.playlist_id}
            )
        elif args.command == "autoplay":
            if args.cursor and args.limit is not None:
                parser.error("Omit --limit when continuing a saved Autoplay cursor")
            body = {"cursor": args.cursor} if args.cursor else {"video_id": args.video_id}
            if args.limit is not None:
                body["limit"] = args.limit
            result = client.call("/api/autoplay", body)
        elif args.command in ("flush", "reconcile"):
            result = client.call("/api/reporting/" + args.command, {})
        elif args.command == "rate":
            result = client.call(
                "/api/ratings", {"occurrence_id": args.occurrence_id, "value": args.value}
            )
            client.call("/api/reporting/flush", {})
        elif args.command == "replay-events":
            Outbox(settings.data / "client-outbox.sqlite3").flush(client)
            result = {"pending_events_replayed": True}
        elif args.command == "report":
            result = client.call("/api/report", method="GET")
            if args.output:
                private_write(args.output, json.dumps(result, indent=2))
                print(f"Report saved to {args.output}")
                return
        elif args.command == "verify":
            job = client.call(
                "/api/checks/decode", {"tidal_id": args.tidal_id, "expect_hires": args.hires}
            )
            print("Checking source codec and decoding the full recording…", flush=True)
            result = job
            while result["status"] == "running":
                time.sleep(2)
                result = client.call("/api/checks/" + job["id"], method="GET")
            print(json.dumps(result, indent=2))
            if result["status"] != "passed":
                raise SystemExit(1)
            return
        elif args.command == "listen":
            if not args.tidal_id and not args.resume_occurrence:
                parser.error("listen requires --tidal-id or --resume-occurrence")
            mpv = args.mpv or shutil.which("mpv") or Path(".tools/mpv/mpv.exe")
            if not Path(mpv).is_file():
                parser.error("Install mpv or use --mpv PATH; see README.md")
            if args.no_report and args.video_id:
                parser.error("Use --no-report without --video-id to keep this occurrence local")
            result = listen(
                client,
                settings,
                mpv,
                args.tidal_id,
                args.video_id,
                args.resume_occurrence,
                not args.no_report,
            )
        else:
            parser.error("Unknown command")
        print(json.dumps(result, indent=2))
    except (RuntimeError, requests.RequestException) as error:
        message = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print(f"Prototype: {message}", file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
