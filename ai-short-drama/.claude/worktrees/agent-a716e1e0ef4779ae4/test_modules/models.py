"""Domain models for the demo pipeline."""

from dataclasses import dataclass, field
from typing import Dict

from utils import now_iso, slugify


@dataclass
class Item:
    """A raw inbound item awaiting processing."""

    name: str
    payload: Dict[str, str] = field(default_factory=dict)
    created_at: str = field(default_factory=now_iso)

    @property
    def slug(self) -> str:
        return slugify(self.name)


@dataclass
class Result:
    """The processed outcome attached to an item.

    Produced by ``services.process_record`` (formerly ``process_item``).
    """

    item_slug: str
    summary: str
    score: int = 0
    processed_at: str = field(default_factory=now_iso)
