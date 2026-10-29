from typing import List


class Solution:
    def findAnagrams(self, s: str, p: str) -> List[int]:
        res = []
        tmp_p = "".join(sorted(p))
        for i in range(len(s)-len(p)+1):
            tmp_s = "".join(sorted(s[i:i+len(p)]))
            if tmp_s == tmp_p:
                res.append(i)
        return res



if __name__ == '__main__':
    sol = Solution()
    print(sol.findAnagrams('abab','ab'))