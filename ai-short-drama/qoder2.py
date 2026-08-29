"""Qoder2 module - a simple demo."""


def greet(name: str) -> str:
    """Return a greeting message."""
    return f"Hello, {name}! Welcome to Qoder2."


def square(n: int) -> int:
    """Return the square of a number."""
    return n * n


if __name__ == "__main__":
    print(greet("World"))
    print(f"Square of 5: {square(5)}")
