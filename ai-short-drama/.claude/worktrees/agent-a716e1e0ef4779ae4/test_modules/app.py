"""Demo entrypoint wiring the pipeline together."""

from handlers import handle_many, handle_single
from services import process_record
from models import Item


def run_demo():
    """Run a tiny end-to-end demo for manual inspection."""
    single = handle_single("Hello World", {"k": "v"})
    print("single:", single)

    many = handle_many(
        [
            {"name": "Alpha One", "payload": {"a": "1", "b": "2"}},
            {"name": "Beta Two", "payload": {"x": "9"}},
            {"name": "Gamma Three", "payload": {"p": "7", "q": "8", "r": "6"}},
        ],
        chunk_size=2,
        score_cap=10,
    )
    for r in many:
        print("high:", r)

    direct = process_record(Item(name="Direct Call", payload={"only": "one"}))
    print("direct:", direct)


if __name__ == "__main__":
    run_demo()
