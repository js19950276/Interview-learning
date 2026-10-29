from typing import List


class Solution:
    def productExceptSelf(self, nums: List[int]) -> List[int]:
        left, right = [1 for _ in range(len(nums))], [1 for _ in range(len(nums))]