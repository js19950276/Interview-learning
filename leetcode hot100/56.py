import math
from typing import List


class Solution:
    def maxSubArray(self, nums: List[int]) -> int:
        num_tmp = [-math.inf] * len(nums)
        for i, num in enumerate(nums):
            if i == 0:
                num_tmp[i] = num
                continue
            num_tmp[i] = max(num_tmp[i-1] + num, num)
        return max(num_tmp)