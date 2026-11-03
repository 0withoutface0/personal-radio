import re
import unicodedata
from difflib import SequenceMatcher


def normalize(text):
    text = unicodedata.normalize("NFKD", text or "").casefold()
    text = "".join(char for char in text if not unicodedata.combining(char))
    return " ".join(re.sub(r"[^\w\s]", " ", text).split())


PRESENTATION = re.compile(
    r"[\[(]\s*(?:(?:official\s+)?(?:music\s+)?video|"
    r"(?:official\s+)?lyric(?:s|\s+video)?|official\s+audio|audio|[48]k|hd|hq)\s*[\])]",
    re.IGNORECASE,
)
FEATURE = re.compile(r"[\[(]\s*(?:feat\.?|ft\.?|featuring)\s+([^\])]+)[\])]", re.IGNORECASE)
SOUNDTRACK = re.compile(r"[\[(]from\s+[^\])]+[\])]", re.IGNORECASE)


def title_key(title):
    title = PRESENTATION.sub("", title or "")
    title = FEATURE.sub("", title)
    # Soundtrack attribution is not a recording version. Keep any version qualifiers.
    title = SOUNDTRACK.sub(lambda m: m[0] if versions(m[0]) else "", title)
    return normalize(title)


def artist_credit(track):
    names = list(track.get("artists", []))
    for feature in FEATURE.findall(track.get("title", "")):
        names.extend(re.split(r"\s+(?:&|and|x)\s+|,\s*", feature, flags=re.IGNORECASE))
    return {normalize(name) for name in names if normalize(name)}


def same_identity(source, target):
    return (
        bool(title_key(source.get("title")))
        and title_key(source.get("title")) == title_key(target.get("title"))
        and bool(artist_credit(source))
        and artist_credit(source) == artist_credit(target)
        and versions(source["title"]) == versions(target["title"])
        and not (
            source.get("explicit") is not None
            and target.get("explicit") is not None
            and source["explicit"] != target["explicit"]
        )
        and not (
            source.get("isrc")
            and target.get("isrc")
            and normalize(source["isrc"]) != normalize(target["isrc"])
        )
    )


def audio_reference(source, target, *, linked=False):
    """Validate song metadata for a video; never relax the Tidal duration check."""
    if target.get("video_type") not in (None, "MUSIC_VIDEO_TYPE_ATV"):
        return False
    if not target.get("album") or not same_identity(source, target):
        return False
    video_duration, audio_duration = source.get("duration"), target.get("duration")
    if not video_duration or not audio_duration:
        return False
    # A provider-linked counterpart can contain an arbitrarily long video introduction.
    # Search-based resolution is bounded and requires exact title/performer/version identity.
    return linked or -2 <= video_duration - audio_duration <= min(60, audio_duration * 0.25)


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
            None, title_key(source["title"]), title_key(candidate["title"])
        ).ratio()
        artists = artist_credit(source)
        target = artist_credit(candidate)
        artist = len(artists & target) / max(len(artists | target), 1)
        duration = source.get("duration")
        close_duration = (
            duration is not None
            and candidate.get("duration") is not None
            and abs(duration - candidate["duration"]) <= 2
        )
        album = bool(
            source.get("album") and normalize(source["album"]) == normalize(candidate.get("album"))
        )
        if not identifier and (title < 0.97 or artist < 0.99 or not close_duration):
            failures = []
            if title < 0.97:
                failures.append("title differs")
            if artist < 0.99:
                failures.append("artist credits differ")
            if not close_duration:
                failures.append("audio duration differs or is missing")
            reason = reason or "; ".join(failures)
        score = (
            1.0 if identifier else title * 0.5 + artist * 0.3 + close_duration * 0.15 + album * 0.05
        )
        ranked.append({"track": candidate, "score": round(score, 4), "rejection": reason})
    ranked.sort(key=lambda x: x["score"], reverse=True)
    eligible = [x for x in ranked if not x["rejection"]]
    if not eligible:
        detail = ranked[0]["rejection"] if ranked else "no catalog candidates returned"
        return {
            "status": "skipped",
            "reason": f"No confident recording match: {detail}",
            "candidates": ranked,
        }
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
