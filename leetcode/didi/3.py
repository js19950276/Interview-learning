class Solution:
    def lengthOfLongestSubstring(self, s: str) -> int:
        res = 0
        tmp_s = ""
        for _s in s:
            if _s not in tmp_s:
                tmp_s += _s
                continue
            res = max(res, len(tmp_s))
            tmp_s = tmp_s[tmp_s.index(_s)+1:] + _s

        if tmp_s:
            res = max(res, len(tmp_s))

        return res