"""Core services that operate on domain models."""

from models import Item, Result


def process_record(item: Item, score_cap: int = 10) -> Result:
    """Process a single Item and return a Result.

    The score is a naive heuristic based on payload size; the summary
    interpolates the slug so downstream consumers can correlate. The
    optional score_cap allows callers to tighten the upper bound.
    """
    score = min(score_cap, len(item.payload) + len(item.name) // 4)
    summary = f"processed:{item.slug} fields={len(item.payload)}"
    return Result(item_slug=item.slug, summary=summary, score=score)


def batch_process(items, score_cap: int = 10):
    """Process a collection of items, returning a list of results."""
    return [process_record(it, score_cap=score_cap) for it in items]


def is_high_score(result: Result, threshold: int = 7) -> bool:
    """Return True when a result score meets or exceeds the threshold."""
    return result.score >= threshold
