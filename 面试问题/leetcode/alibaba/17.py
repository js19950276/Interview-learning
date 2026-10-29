from typing import List


class Solution:
    def __init__(self):
        self.letterMap = {
            "2": "abc",
            "3": "def",
            "4": "ghi",
            "5": "jkl",
            "6": "mno",
            "7": "pqrs",
            "8": "tuv",
            "9": "wxyz"
        }

    def letterCombinations(self, digits: str) -> List[str]:
        res = []
        def backtrace(sub_digits, sub_res):
            if not sub_digits:
                res.extend(sub_res)
                return

            digit = self.letterMap[sub_digits[0]]
            tmp = []
            for d in digit:
                if not sub_res:
                    tmp.append(d)
                else:
                    for r in sub_res:
                        tmp.append(r+d)
            backtrace(sub_digits[1:], tmp)
        backtrace(digits, [])
        return res

if __name__ == '__main__':
    digits = "23"
    a = Solution().letterCombinations(digits)
    print(a)
