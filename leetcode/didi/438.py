from typing import List, Counter


class Solution:
    def findAnagrams(self, s: str, p: str) -> List[int]:
        res = []
        set_p = Counter(p)
        for i in range(len(s)-len(p)+1):
            tmp = s[i:i+len(p)]
            if Counter(tmp) == set_p:
                res.append(i)
        return res


if __name__ == '__main__':
    ans = Solution()
    print(ans.findAnagrams('ababababab', 'aab'))