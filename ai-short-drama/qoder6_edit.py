"""Qoder6 module."""


def greet(name):
    """Return a greeting message."""
    return f"Hello, {name}!"


def subtract(a, b):
    """Subtract two numbers."""
    return a - b


if __name__ == "__main__":
    print(greet("World"))
    print(f"10 - 4 = {subtract(10, 4)}")
