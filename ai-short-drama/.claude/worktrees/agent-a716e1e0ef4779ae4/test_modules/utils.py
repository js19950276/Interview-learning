"""Utility helpers shared across modules."""

from datetime import datetime


def now_iso() -> str:
    """Return the current timestamp in ISO 8601 format."""
    return datetime.utcnow().isoformat()


def slugify(text: str) -> str:
    """Convert arbitrary text into a lowercase, hyphen-separated slug."""
    cleaned = "".join(ch.lower() if ch.isalnum() else "-" for ch in text)
    while "--" in cleaned:
        cleaned = cleaned.replace("--", "-")
    return cleaned.strip("-")


def chunked(records, size):
    """Yield successive chunks of the iterable with the given size.

    The parameter was renamed from ``items`` to ``records`` to match the
    new ``process_record`` naming used downstream.
    """
    if size <= 0:
        raise ValueError("size must be positive")
    bucket = []
    for record in records:
        bucket.append(record)
        if len(bucket) == size:
            yield bucket
            bucket = []
    if bucket:
        yield bucket
