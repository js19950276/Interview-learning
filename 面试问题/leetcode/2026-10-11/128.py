class Solution:
    def longestConsecutive(self, nums: list[int]) -> int:
        set_nums = set(nums)
        res = 0
        for num in nums:
            if num - 1 in set_nums:
                continue
            tmp = num
            while tmp in set_nums:
                tmp += 1
            res = max(res, tmp - num)
        return res
