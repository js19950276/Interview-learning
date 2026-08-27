# utils — small pure helpers, no external deps


def clamp(value, low, high):
    """Clamp `value` into the inclusive [low, high] range."""
    if low > high:
        low, high = high, low
    return max(low, min(high, value))


def is_even(n):
    return n % 2 == 0


def is_odd(n):
    return n % 2 != 0


def chunk(items, size):
    """Split `items` into consecutive chunks of length `size`."""
    if size <= 0:
        raise ValueError("size must be positive")
    for i in range(0, len(items), size):
        yield items[i:i + size]


if __name__ == "__main__":
    assert clamp(5, 0, 10) == 5
    assert clamp(-3, 0, 10) == 0
    assert is_even(4) and not is_even(3)
    assert list(chunk([1, 2, 3, 4, 5], 2)) == [[1, 2], [3, 4], [5]]
    print("[PASS] utils")
