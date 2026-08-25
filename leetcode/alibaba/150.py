import math
from typing import List


class Solution:
    def evalRPN(self, tokens: List[str]) -> int:
        stack = []
        for t in tokens:
            if t not in ("+", "-", "*", "/"):
                stack.append(t)
                continue
            num2 = int(stack.pop())
            num1 = int(stack.pop())
            if t == "+":
                num = num1 + num2
            elif t == "-":
                num = num1 - num2
            elif t == "*":
                num = num1 * num2
            else:
                num = math.trunc(num1 / num2)
            stack.append(num)
        return stack[-1]

if __name__ == '__main__':
    tokens = ["10", "6", "9", "3", "+", "-11", "*", "/", "*", "17", "+", "5", "+"]
    s = Solution().evalRPN(tokens)
    print(s)