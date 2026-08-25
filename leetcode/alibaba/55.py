from typing import List


class Solution:
    def canJump(self, nums: List[int]) -> bool:
        mx = 0
        for i in range(1,len(nums)):
            if i > mx:
                return False
            mx = max(mx, nums[i] + i)
        else:
            return True