class Solution:
    def lengthOfLongestSubstring(self, s: str) -> int:
        res = 0
        sub_s = ""
        for _s in s:
            if _s not in sub_s:
                sub_s += _s
            else:
                res = max(res, len(sub_s))
                sub_s = sub_s[sub_s.index(_s): len(sub_s)]
        return res