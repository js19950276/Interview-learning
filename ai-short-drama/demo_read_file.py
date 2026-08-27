# demo_read_file — demonstrate reading a file and returning line-numbered stats


def demo_read_file(path):
    """Read the file at `path` and return (numbered_lines, stats).

    numbered_lines: list of "N|<line>" strings (1-indexed, like the read_file tool).
    stats: dict with keys total_lines, char_count, blank_lines.
    Raises FileNotFoundError if the path does not exist.
    """
    with open(path, "r", encoding="utf-8") as fh:
        raw_lines = fh.read().splitlines()

    numbered_lines = [f"{i + 1}|{line}" for i, line in enumerate(raw_lines)]
    char_count = sum(len(line) for line in raw_lines)
    blank_lines = sum(1 for line in raw_lines if line.strip() == "")

    stats = {
        "total_lines": len(raw_lines),
        "char_count": char_count,
        "blank_lines": blank_lines,
    }
    return numbered_lines, stats


if __name__ == "__main__":
    # Self-demo: read this very file, mirroring how the read_file tool behaves.
    import os

    self_path = os.path.abspath(__file__)
    numbered, stats = demo_read_file(self_path)

    # --- show the first few numbered lines (read_file style) ---
    print(f"# --- {os.path.basename(self_path)} (first 5 lines) ---")
    for line in numbered[:5]:
        print(line)

    # --- show stats ---
    print("\n# --- stats ---")
    print(f"total_lines : {stats['total_lines']}")
    print(f"char_count  : {stats['char_count']}")
    print(f"blank_lines : {stats['blank_lines']}")

    # --- assertions (utils.py convention) ---
    assert stats["total_lines"] > 0, "self-read should yield at least one line"
    assert stats["char_count"] > 0, "self-read should yield non-zero chars"
    assert isinstance(numbered[0], str) and "|" in numbered[0], "line format N|..."
    assert all(k in stats for k in ("total_lines", "char_count", "blank_lines"))
    print("\n[PASS] demo_read_file")
