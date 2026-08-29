"""Stack-based RPN calculator - v3 with logging."""

import logging
from typing import List

logger = logging.getLogger(__name__)


class RPNCalculator:
    """Reverse Polish Notation calculator using a stack."""

    OPERATORS = {"+", "-", "*", "/"}

    def __init__(self):
        self.stack: List[float] = []

    def push(self, value: float) -> None:
        self.stack.append(value)

    def _apply(self, op: str) -> None:
        if len(self.stack) < 2:
            raise ValueError(f"Not enough operands for '{op}'")
        b = self.stack.pop()
        a = self.stack.pop()
        if op == "+":
            self.stack.append(a + b)
        elif op == "-":
            self.stack.append(a - b)
        elif op == "*":
            self.stack.append(a * b)
        elif op == "/":
            if b == 0:
                raise ValueError("Cannot divide by zero")
            self.stack.append(a / b)

    def evaluate(self, expression: str) -> float:
        logger.debug("Evaluating expression: %s", expression)
        for token in expression.split():
            if token in self.OPERATORS:
                self._apply(token)
            else:
                self.push(float(token))
        if len(self.stack) != 1:
            raise ValueError("Invalid expression: stack not reduced to one")
        return self.stack[-1]

    def reset(self) -> None:
        self.stack.clear()
