import json
import threading
from contextlib import nullcontext

from .providers import ProviderUnavailable


class Reporter:
    def __init__(self, store, providers, *, bound_accounts=False):
        self.store = store
        self.providers = providers
        self.lock = threading.Lock()
        self.bound_accounts = bound_accounts

    def _matches(self, row):
        if not self.bound_accounts:
            return True
        identity = self.store.bound_account(row["occurrence_id"], row["provider"])
        return bool(identity and identity == self.providers.identity(row["provider"]))

    def flush(self):
        # Explicit dispatch only during the prototype. Pending work survives restarts.
        with self.lock, self.providers.lock if self.bound_accounts else nullcontext():
            for row in self.store.submissions():
                if row["state"] != "pending":
                    continue
                if not self._matches(row):
                    self.store.outcome(
                        row["id"],
                        "pending",
                        "Held for the original account; identity could not be verified.",
                        expected_state="pending",
                    )
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
                    continue
                if not self.store.claim(row["id"], baseline):
                    continue
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
            self.reconcile()

    def reconcile(self):
        with self.providers.lock if self.bound_accounts else nullcontext():
            self._reconcile()

    def _reconcile(self):
        rows = [
            row for row in self.store.submissions() if row["state"] in ("submitted", "uncertain")
        ]
        history = None
        for row in rows:
            if not self._matches(row):
                continue
            try:
                if row["provider"] == "tidal":
                    if self.providers.check_tidal_favorite(row["tidal_id"], row["value"] == "LIKE"):
                        detail = (
                            "Favorite visible on Tidal"
                            if row["value"] == "LIKE"
                            else "Removal from Tidal favorites verified"
                        )
                        self.store.outcome(row["id"], "visible", detail)
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
