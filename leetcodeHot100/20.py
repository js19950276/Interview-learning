class Solution:
    def __init__(self):
        self.left = {"(", "[", "{"}
        self.right = {")", "[", "{"}
        self.left2right = {
            "(": ")",
            "[": "]",
            "{": "}"
        }

    def isValid(self, s: str) -> bool:
        stack = []
        for _s in s:
            if _s in self.left:
                stack.append(_s)
            else:
                if len(stack) == 0:
                    return False
                _left = stack.pop()
                if _s == self.left2right[_left]:
                    continue
                else:
                    return False
        if stack:
            return False
        return True