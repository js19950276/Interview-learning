from typing import List


class Solution:
    def longestConsecutive(self, nums: List[int]) -> int:
        st = set(nums)
        ans = 0
        for x in st:
            if x - 1 in st:
                continue
            y = x + 1
            while y in st:
                y += 1
            ans = max(ans, y - x)
        return ans


if __name__ == '__main__':
    a = Solution()
    print(a.longestConsecutive([100,4,200,1,3,2]))
