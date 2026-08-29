"""Request-style handlers that glue services and models together."""

from models import Item
from services import batch_process, is_high_score, process_record
from utils import chunked


def handle_single(name: str, payload=None, score_cap: int = 10):
    """Build an Item from primitives and process it."""
    item = Item(name=name, payload=payload or {})
    return process_record(item, score_cap=score_cap)


def handle_many(raw_items, chunk_size: int = 2, score_cap: int = 10):
    """Process raw item dicts in chunks and return high-scoring results."""
    items = [Item(name=r["name"], payload=r.get("payload", {})) for r in raw_items]
    high = []
    for batch in chunked(items, chunk_size):
        for result in batch_process(batch, score_cap=score_cap):
            if is_high_score(result):
                high.append(result)
    return high
