import re
import unicodedata
from difflib import SequenceMatcher


def normalize(text):
    text = unicodedata.normalize("NFKD", text or "").casefold()
    return " ".join(re.sub(r"[^\w\s]", " ", text).split())


def versions(title):
    normalized = normalize(title)
    return {
        word
        for word in (
            "live",
            "remix",
            "remaster",
            "remastered",
            "acoustic",
            "instrumental",
            "edit",
            "karaoke",
            "sped",
            "slowed",
        )
        if word in normalized.split()
    }


def match_recording(source, candidates):
    ranked = []
    for candidate in candidates:
        reason = None
        if versions(source["title"]) != versions(candidate["title"]):
            reason = "recording version differs"
        elif (
            source.get("explicit") is not None
            and candidate.get("explicit") is not None
            and source["explicit"] != candidate["explicit"]
        ):
            reason = "explicit/clean version differs"
        elif (
            source.get("isrc")
            and candidate.get("isrc")
            and source["isrc"].upper() != candidate["isrc"].upper()
        ):
            reason = "recording identifiers differ"
        identifier = bool(
            source.get("isrc")
            and candidate.get("isrc")
            and source["isrc"].upper() == candidate["isrc"].upper()
        )
        title = SequenceMatcher(
            None, normalize(source["title"]), normalize(candidate["title"])
        ).ratio()
        artists = {normalize(x) for x in source.get("artists", [])}
        target = {normalize(x) for x in candidate.get("artists", [])}
        artist = len(artists & target) / max(len(artists | target), 1)
        duration = source.get("duration")
        close_duration = duration is not None and abs(duration - candidate["duration"]) <= 2
        album = bool(
            source.get("album") and normalize(source["album"]) == normalize(candidate.get("album"))
        )
        if not identifier and (title < 0.97 or artist < 0.99 or not close_duration):
            reason = reason or "insufficient title, artist, or duration agreement"
        score = (
            1.0 if identifier else title * 0.5 + artist * 0.3 + close_duration * 0.15 + album * 0.05
        )
        ranked.append({"track": candidate, "score": round(score, 4), "rejection": reason})
    ranked.sort(key=lambda x: x["score"], reverse=True)
    eligible = [x for x in ranked if not x["rejection"]]
    if not eligible:
        return {"status": "skipped", "reason": "No confident recording match", "candidates": ranked}
    best = eligible[0]
    if len(eligible) > 1 and best["score"] - eligible[1]["score"] < 0.04:
        isrcs = {x["track"].get("isrc") for x in eligible if best["score"] - x["score"] < 0.04}
        if None in isrcs or len(isrcs) != 1:
            return {
                "status": "skipped",
                "reason": "Ambiguous recordings; save a manual correction",
                "candidates": ranked,
            }
    return {
        "status": "matched",
        "track": best["track"],
        "score": best["score"],
        "candidates": ranked,
    }
