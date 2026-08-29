"""Qoder1 module - a simple demo."""


def greet(name: str) -> str:
    """Return a greeting message."""
    return f"Hello, {name}! Welcome to Qoder."


def add(a: int, b: int) -> int:
    """Add two numbers."""
    return a + b


def multiply(a: float, b: float) -> float:
    """Multiply two numbers."""
    return a * b


def fibonacci(n: int) -> list[int]:
    """Generate the first n Fibonacci numbers."""
    if n <= 0:
        return []
    seq = [0, 1]
    while len(seq) < n:
        seq.append(seq[-1] + seq[-2])
    return seq[:n]


def is_palindrome(s: str) -> bool:
    """Check if a string is a palindrome (ignoring case and spaces)."""
    cleaned = s.replace(" ", "").lower()
    return cleaned == cleaned[::-1]


def flatten(nested: list) -> list:
    """Flatten a nested list into a single-level list."""
    result = []
    for item in nested:
        if isinstance(item, list):
            result.extend(flatten(item))
        else:
            result.append(item)
    return result


def word_count(text: str) -> dict[str, int]:
    """Count the frequency of each word in the text."""
    words = text.lower().split()
    return {w: words.count(w) for w in set(words)}


def clamp(value: float, min_val: float, max_val: float) -> float:
    """Clamp a value between min and max."""
    return max(min_val, min(value, max_val))


if __name__ == "__main__":
    print(greet("World"))
    print(f"1 + 2 = {add(1, 2)}")
    print(f"3 × 4 = {multiply(3, 4)}")
    print(f"Fibonacci(10): {fibonacci(10)}")
    print(f"'racecar' is palindrome: {is_palindrome('racecar')}")
    print(f"'hello world' is palindrome: {is_palindrome('hello world')}")
    print(f"Flatten [1,[2,[3,4],5]]: {flatten([1, [2, [3, 4], 5]])}")
    print(f"Word count: {word_count('the cat sat on the mat the cat')}")
    print(f"Clamp 15 to [0,10]: {clamp(15, 0, 10)}")
    print(f"Clamp -3 to [0,10]: {clamp(-3, 0, 10)}")
