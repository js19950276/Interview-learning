class Solution:
    def lengthOfLongestSubstring(self, s: str) -> int:
        res = 0
        tmp_s = ""
        for i, v in enumerate(s):
            if i == 0:
                tmp_s += v
                continue
            if v in tmp_s:
                res = max(res, len(tmp_s))
                tmp_s = tmp_s[tmp_s.index(v)+1:] + v
            else:
                tmp_s += v
        else:
            return max(res, len(tmp_s))

if __name__ == '__main__':
    sol = Solution()
    print(sol.lengthOfLongestSubstring("abcabcbb"))