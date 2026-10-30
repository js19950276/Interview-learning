import math


class Solution:
    def evalRPN(self, tokens: list[str]) -> int:
        stack = []
        for token in tokens:
            if token in ["+", "-", "*", "/"]:
                num1 = stack.pop()
                num2 = stack.pop()
                num = eval(num2 + token + num1)
                stack.append(str(math.trunc(num)))
            else:
                stack.append(token)
        return math.trunc(float(stack[-1]))

if __name__ == '__main__':
    tokens = ["10","6","9","3","+","-11","*","/","*","17","+","5","+"]
    print(Solution().evalRPN(tokens))