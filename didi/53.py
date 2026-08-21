import math
from typing import List


class Solution:
    def maxSubArray(self, nums: List[int]) -> int:
        dp = [-math.inf for _ in range(len(nums))]
        for i, num in enumerate(nums):
            if i == 0:
                dp[i] = num
                continue
            dp[i] = max(num, dp[i-1] + num)
        return max(dp)

