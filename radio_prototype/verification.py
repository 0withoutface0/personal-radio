import json
import shutil
import subprocess


def verify_decode(url, token, track, plan, expect_hires, store):
    """Read and decode an entire source to a null sink; never creates an audio download."""
    kind = "hires_decode" if expect_hires else "lossless_decode"
    details = {
        "tidal_id": track["id"],
        "expected_duration": track["duration"],
        "source": plan.public(),
        "audible_playback": "not_tested_by_decoder",
    }
    try:
        if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
            raise RuntimeError("FFmpeg and ffprobe must be installed on the prototype host")
        input_options = ["-headers", f"Authorization: Bearer {token}\r\n"]
        if plan.kind == "hls":
            input_options += ["-allowed_extensions", "ALL"]
        probe = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                *input_options,
                "-i",
                url,
                "-select_streams",
                "a:0",
                "-show_streams",
                "-of",
                "json",
            ],
            capture_output=True,
            timeout=120,
            text=True,
        )
        if probe.returncode:
            raise RuntimeError("ffprobe could not read the authenticated source")
        streams = json.loads(probe.stdout).get("streams", [])
        if len(streams) != 1:
            raise RuntimeError("Expected exactly one audio stream")
        source = streams[0]
        codec = source.get("codec_name")
        bits = int(source.get("bits_per_raw_sample") or source.get("bits_per_sample") or 0)
        rate = int(source.get("sample_rate") or 0)
        details["measured"] = {"codec": codec, "bit_depth": bits, "sample_rate": rate}
        if codec != "flac" or bits < 16 or rate < 44100:
            raise RuntimeError("Decoded source is not verified lossless FLAC")
        hires = bits > 16 or rate > 48000
        if expect_hires != hires:
            raise RuntimeError("Measured resolution does not match the requested verification case")
        # -xerror rejects truncated/corrupt segments. Decoded PCM is discarded, never re-encoded.
        decoded = subprocess.run(
            [
                "ffmpeg",
                "-v",
                "error",
                "-xerror",
                "-nostdin",
                "-nostats",
                "-progress",
                "pipe:1",
                *input_options,
                "-i",
                url,
                "-map",
                "0:a:0",
                "-f",
                "null",
                "-",
            ],
            capture_output=True,
            timeout=max(180, track["duration"] * 3),
            text=True,
        )
        # stderr may contain signed URLs: retain only safe evidence, never command output.
        if decoded.returncode:
            raise RuntimeError("Full-source decode failed or was interrupted")
        progress = dict(line.split("=", 1) for line in decoded.stdout.splitlines() if "=" in line)
        seconds = int(progress.get("out_time_us", "0")) / 1_000_000
        details["decoded_seconds"] = seconds
        if progress.get("progress") != "end" or seconds < track["duration"] - 1:
            raise RuntimeError(
                "Decoded duration is shorter than the full recording (possible preview)"
            )
        details["server_lossy_conversion"] = False
        store.evidence(kind, "passed", details)
        return {"status": "passed", **details}
    except Exception as error:
        # Our own RuntimeErrors contain static descriptions; provider/process exceptions do not.
        details["error"] = str(error) if type(error) is RuntimeError else type(error).__name__
        store.evidence(kind, "failed", details)
        return {"status": "failed", **details}
