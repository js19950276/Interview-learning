from typing import List


class Solution:
    def partition(self, s: str) -> List[List[str]]:
        res = []
        def backtrace(_s, tmp):
            for i in range(len(_s)):
                sub_s = _s[:i] + _s[i+1:]
                if sub_s == sub_s[::-1]:
                    tmp.append(sub_s)
                else:
                    backtrace(sub_s, )
        backtrace(s, [])
        return res

if __name__ == '__main__':
    a = Solution().partition(s = "aab")
    print(a)
