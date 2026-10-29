from typing import List


class Solution:
    def twoSum(self, nums: List[int], target: int) -> List[int]:
        num_map = {}
        for i, v in enumerate(nums):
            minus = target - v
            if minus in num_map:
                return [num_map[minus], i]
            else:
                num_map[v] = i
        else:
            return []
