from typing import List


class Solution:
    def longestConsecutive(self, nums: List[int]) -> int:
        nums_set = set(nums)

        res = 0

        for n in nums:
            if n - 1 in nums_set:
                continue
            next_n = n + 1
            tmp = 1
            while next_n in nums_set:
                tmp += 1
            res = max(res, tmp)
        return res