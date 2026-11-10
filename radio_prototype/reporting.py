import json
import threading
import time
from contextlib import nullcontext

from .providers import ProviderUnavailable


class Reporter:
    retry_delays = (15, 60, 300)

    def __init__(self, store, providers, *, bound_accounts=False):
        self.store = store
        self.providers = providers
        self.lock = threading.Lock()
        self.bound_accounts = bound_accounts
        self._schedule_lock = threading.Lock()
        self._timer = None
        self._running = self._requested = self._retry_now = self._closed = False
        self._retries = {}

    def dispatch(self, *, retry_now=False):
        with self._schedule_lock:
            if self._closed:
                return
            self._requested = True
            self._retry_now |= retry_now
            if not self._running:
                if self._timer is not None:
                    self._timer.cancel()
                self._schedule(0)

    def _schedule(self, delay):
        self._timer = threading.Timer(delay, self._work)
        self._timer.daemon = True
        self._timer.start()

    def _work(self):
        with self._schedule_lock:
            if self._closed or self._timer is not threading.current_thread():
                return
            self._timer = None
            self._running = True
            retry_now = self._retry_now
            self._requested = self._retry_now = False
        try:
            self.flush(automatic=True, retry_now=retry_now)
        finally:
            with self._schedule_lock:
                self._running = False
                if not self._closed:
                    due = [due for _, due in self._retries.values() if due is not None]
                    if self._requested:
                        self._schedule(0)
                    elif due:
                        self._schedule(max(0, min(due) - time.monotonic()))

    def close(self):
        with self._schedule_lock:
            self._closed = True
            if self._timer is not None:
                self._timer.cancel()
                self._timer = None

    def _due(self, submission_id):
        _, due = self._retries.get(submission_id, (0, 0))
        return due is not None and time.monotonic() >= due

    def _defer(self, submission_id):
        tries, _ = self._retries.get(submission_id, (0, 0))
        due = time.monotonic() + self.retry_delays[tries] if tries < len(self.retry_delays) else None
        self._retries[submission_id] = (tries + 1, due)

    def _hold_reason(self, row):
        if not self.bound_accounts:
            return None
        provider = row["provider"]
        identity = self.store.bound_account(row["occurrence_id"], provider)
        if provider == "youtube" and identity is None:
            return "Saved without a verified channel. Review held YouTube activity in Settings."
        current = self.providers.identity(provider)
        if not identity or not current:
            return "Held for the original account; identity could not be verified."
        if identity != current:
            return "Held for a different account. Reconnect the original account."
        return None

    def flush(self, *, automatic=False, retry_now=False):
        with self.lock, self.providers.lock if self.bound_accounts else nullcontext():
            rows = self.store.submissions()
            if automatic:
                if retry_now:
                    self._retries.clear()
                candidates = {row["id"] for row in rows if row["state"] in (
                    "pending", "submitted", "uncertain",
                )}
                self._retries = {
                    key: value for key, value in self._retries.items() if key in candidates
                }
            for row in rows:
                if row["state"] != "pending" or (automatic and not self._due(row["id"])):
                    continue
                held = self._hold_reason(row)
                if held:
                    self.store.outcome(
                        row["id"],
                        "pending",
                        held,
                        expected_state="pending",
                    )
                    if automatic:
                        self._retries.pop(row["id"], None)
                    continue
                # Preflight failures have not sent any mutation and remain safely pending.
                try:
                    if row["provider"] == "tidal":
                        self.providers.td()
                    else:
                        self.providers.yt()
                    baseline = (
                        [x.get("videoId") for x in self.providers.history()]
                        if row["kind"] == "history"
                        else None
                    )
                except Exception as error:
                    detail = (
                        str(error)
                        if isinstance(error, ProviderUnavailable)
                        else f"Account unavailable ({type(error).__name__})"
                    )
                    self.store.outcome(row["id"], "pending", detail, expected_state="pending")
                    if automatic:
                        self._defer(row["id"])
                    continue
                if not self.store.claim(row["id"], baseline):
                    continue
                if automatic:
                    self._retries.pop(row["id"], None)
                try:
                    if row["provider"] == "tidal":
                        accepted = self.providers.set_tidal_favorite(
                            row["tidal_id"], row["value"] == "LIKE"
                        )
                        if not accepted:
                            self.store.outcome(
                                row["id"],
                                "uncertain",
                                "Tidal did not acknowledge; check without resending",
                            )
                            continue
                    elif row["kind"] == "history":
                        status = self.providers.submit_history(row["video_id"])
                        if status != 204:
                            self.store.outcome(
                                row["id"],
                                "uncertain",
                                f"History returned HTTP {status}; do not resend",
                            )
                            continue
                    else:
                        self.providers.rate(row["video_id"], row["value"])
                    self.store.outcome(
                        row["id"], "submitted", "Request returned; account check pending"
                    )
                except Exception as error:
                    self.store.outcome(
                        row["id"],
                        "uncertain",
                        f"Mutation outcome unknown ({type(error).__name__}); do not resend",
                    )
            self._reconcile(automatic=automatic)

    def reconcile(self):
        with self.lock, self.providers.lock if self.bound_accounts else nullcontext():
            self._reconcile()

    def _reconcile(self, *, automatic=False):
        rows = [
            row for row in self.store.submissions() if row["state"] in ("submitted", "uncertain")
        ]
        history = None
        for row in rows:
            if automatic and not self._due(row["id"]):
                continue
            if self._hold_reason(row):
                if automatic:
                    self._retries.pop(row["id"], None)
                continue
            if automatic:
                self._defer(row["id"])
            try:
                if row["provider"] == "tidal":
                    if self.providers.check_tidal_favorite(row["tidal_id"], row["value"] == "LIKE"):
                        detail = (
                            "Favorite visible on Tidal"
                            if row["value"] == "LIKE"
                            else "Removal from Tidal favorites verified"
                        )
                        self.store.outcome(row["id"], "visible", detail)
                        if automatic:
                            self._retries.pop(row["id"], None)
                    else:
                        self.store.outcome(
                            row["id"],
                            row["state"],
                            "Favorite state unverified; check Tidal directly",
                        )
                elif row["kind"] == "history":
                    if history is None:
                        history = self.providers.history()
                    visible = any(x.get("videoId") == row["video_id"] for x in history)
                    if visible:
                        # Visibility alone cannot identify one occurrence among repeats.
                        self.store.outcome(
                            row["id"],
                            "visible",
                            "Song visible in account history; occurrence attribution unverified",
                        )
                        if automatic:
                            self._retries.pop(row["id"], None)
                        baseline = json.loads(row["baseline"] or "null")
                        verified_new = (
                            baseline is not None
                            and row["video_id"] not in baseline
                            and row["state"] == "submitted"
                        )
                        self.store.evidence(
                            "history_visibility",
                            "passed" if verified_new else "uncertain",
                            {
                                "video_id": row["video_id"],
                                "submission_id": row["id"],
                                "new_since_preflight": verified_new,
                                "recap": "unverified",
                            },
                        )
                elif self.providers.check_rating(row["video_id"], row["value"]):
                    self.store.outcome(row["id"], "visible", "Like visible on account")
                    if automatic:
                        self._retries.pop(row["id"], None)
                else:
                    self.store.outcome(
                        row["id"],
                        row["state"],
                        "Rating visibility unverified; check YouTube Music directly",
                    )
            except Exception as error:
                self.store.outcome(
                    row["id"],
                    row["state"],
                    f"Account check unavailable ({type(error).__name__}); no resubmission",
                )
