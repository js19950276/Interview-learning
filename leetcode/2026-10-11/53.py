import math


class Solution:
    def maxSubArray(self, nums: list[int]) -> int:
        dp = [-math.inf for _ in range(len(nums))]
        for i, num in enumerate(nums):
            if i == 0:
                dp[i] = num
            else:
                dp[i] = max(dp[i-1] + num, num)
        return max(dp)
