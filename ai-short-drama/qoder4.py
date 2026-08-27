"""Qoder4 module - a simple demo."""


def greet(name: str) -> str:
    """Return a greeting message."""
    return f"Hello, {name}! Welcome to Qoder4."


def subtract(a: int, b: int) -> int:
    """Subtract two numbers."""
    return a - b


if __name__ == "__main__":
    print(greet("World"))
    print(f"10 - 3 = {subtract(10, 3)}")
