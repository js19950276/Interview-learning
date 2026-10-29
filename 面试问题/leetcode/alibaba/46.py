from typing import List


class Solution:
    def permute(self, nums: List[int]) -> List[List[int]]:
        res = []
        def backtrace(sub_nums, sub_res):
            if len(sub_res) == len(nums):
                res.append(sub_res)
            else:
                for i in range(len(sub_nums)):
                    backtrace(sub_nums[:i] + sub_nums[i+1:], sub_res + [sub_nums[i]])
        backtrace(nums, [])
        return res