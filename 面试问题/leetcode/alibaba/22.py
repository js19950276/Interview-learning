from typing import List


class Solution:
    def generateParenthesis(self, n: int) -> List[str]:
        res = list()
        def backtrace(_n, sub_res):
            if not _n:
                if sub_res not in res:
                    res.append(sub_res)
                return
            for i in range(len(sub_res)):
                backtrace(_n - 1, sub_res[:i] + "()" + sub_res[i:])
        if n:
            backtrace(n-1, "()")
        return res

if __name__ == '__main__':
    a = Solution()
    print(a.generateParenthesis(n = 3))