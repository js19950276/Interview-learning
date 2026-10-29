from typing import List


class Solution:
    def findAnagrams(self, s: str, p: str) -> List[int]:
        len_p = len(p)
        sort_p = "".join(sorted(p))
        res = []
        for i in range(len(s) - len_p):
            if "".join(sorted(s[i: i+len_p])) == sort_p:
                res.append(i)
        return res
