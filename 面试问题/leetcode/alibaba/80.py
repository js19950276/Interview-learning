from collections import defaultdict
from typing import List


class Solution:
    def removeDuplicates(self, nums: List[int]) -> int:
        map = defaultdict(int)
        res = 0
        for num in nums:
            if map[num] > 2:
                continue
            else:
                map[num] += 1
                res += 1
        return res

