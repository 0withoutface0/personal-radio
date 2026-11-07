"""Inspect a bounded prefix of the original lossless audio or fMP4 init asset."""

MAX_PREFIX = 256 * 1024


def _streaminfo(metadata):
    if len(metadata) < 38 or metadata[0] & 127 or metadata[1:4] != b"\0\0\x22":
        raise ValueError("Missing FLAC STREAMINFO")
    fields = int.from_bytes(metadata[14:22], "big")
    rate = fields >> 44
    bits = ((fields >> 36) & 31) + 1
    if not 0 < rate <= 655350 or not 4 <= bits <= 32:
        raise ValueError("Invalid FLAC resolution")
    return bits, rate


def _boxes(data):
    while len(data) >= 8:
        size = int.from_bytes(data[:4], "big")
        kind = data[4:8]
        header = 8
        if size == 1:
            header = 16
            size = int.from_bytes(data[8:16], "big")
        if size < header or size > len(data):
            return
        yield kind, data[header:size]
        data = data[size:]


def _find_box(data, path):
    name, skip = path[0]
    for kind, content in _boxes(data):
        if kind == name:
            if len(path) == 1:
                return content[skip:]
            match = _find_box(content[skip:], path[1:])
            if match is not None:
                return match
    return None


def probe_resolution(data, kind):
    if kind == "direct" and data.startswith(b"fLaC"):
        return _streaminfo(data[4:])
    if kind == "hls":
        metadata = _find_box(
            data,
            [
                (b"moov", 0),
                (b"trak", 0),
                (b"mdia", 0),
                (b"minf", 0),
                (b"stbl", 0),
                (b"stsd", 8),
                (b"fLaC", 28),
                (b"dfLa", 4),
            ],
        )
        if metadata is not None:
            return _streaminfo(metadata)
    raise ValueError("Unrecognized FLAC source header")


def source_quality(streams, stream_id, plan):
    result = {"verified": False, "codec": "FLAC", "source_quality": plan.quality}
    try:
        limit = 42 if plan.kind == "direct" else MAX_PREFIX
        with streams.open_asset(stream_id, 0, f"bytes=0-{limit - 1}") as response:
            data = bytearray()
            for chunk in response.iter_content(chunk_size=min(8192, limit)):
                data.extend(chunk[: limit - len(data)])
                if len(data) == limit:
                    break
        bits, rate = probe_resolution(bytes(data), plan.kind)
        result.update(verified=True, bit_depth=bits, sample_rate=rate)
    except Exception:
        # No signed URL or media details from an upstream exception leave the probe.
        pass
    return result
