import math
from typing import List


class Solution:
    def findMin(self, nums: List[int]) -> int:
        left, right = 0, len(nums) - 1
        while left <= right:
            mid = (left + right) // 2
            if nums[mid] < nums[-1]:
                right = mid - 1
            else:
                left = mid + 1

        return nums[left]

if __name__ == '__main__':
    a = Solution().findMin([4,5,6,7,0,1,2])
    print(a)