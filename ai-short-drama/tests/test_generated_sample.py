import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from utils import clamp, chunk


def test_clamp_bounds():
    assert clamp(5, 0, 10) == 5
    assert clamp(-1, 0, 10) == 0
    assert clamp(99, 0, 10) == 10


def test_clamp_equal_bounds():
    assert clamp(7, 7, 7) == 7


def test_chunk_even_split():
    assert list(chunk(list(range(6)), 2)) == [[0, 1], [2, 3], [4, 5]]


def test_chunk_remainder():
    assert list(chunk([1, 2, 3, 4, 5], 2)) == [[1, 2], [3, 4], [5]]


def test_chunk_empty():
    assert list(chunk([], 3)) == []


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            print(f"[PASS] {name}")
    print("all tests passed")
