from collections import defaultdict
from typing import List


class Solution:
    def majorityElement(self, nums: List[int]) -> int:
        map = defaultdict(int)
        for n in nums:
            map[n] += 1

        for i, v in map.items():
            if v > len(nums) // 2:
                return i