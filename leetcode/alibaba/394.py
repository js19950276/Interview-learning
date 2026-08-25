class Solution:
    def decodeString(self, s: str) -> str:
        def dfs(s, i):
            k, res = 0, ""
            while i < len(s):
                if "0" <= s[i] <= "9":
                    k = k * 10 + int(s[i])
                elif s[i] == "[":
                    i, _s = dfs(s, i + 1)
                    res += k * _s
                elif s[i] == "]":
                    return i, res
                else:
                    res += s[i]
                i += 1
            return res
        return dfs(s, 0)

if __name__ == '__main__':
    a = Solution().decodeString(s = "3[a]2[bc]")
    print(a)