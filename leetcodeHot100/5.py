class Solution:
    def longestPalindrome(self, s: str) -> str:
        if not s:
            return ""
        if s == s[::-1]:
            return s

        left = self.longestPalindrome(s[1:])
        right = self.longestPalindrome(s[:-1])

        if len(left) > len(right):
            return left
        else:
            return right


if __name__ == '__main__':
    s = "cbbd"
    solution = Solution()
    print(solution.longestPalindrome(s))
