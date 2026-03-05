from typing import List


class Solution:
    def moveZeroes(self, nums: List[int]) -> None:
        """
        Do not return anything, modify nums in-place instead.
        """
        n = 0
        for num in nums:
            if num:
                nums[n] = num
                n += 1
        for i in range(n, len(nums)):
            nums[i] = 0

if __name__ == '__main__':
    print(Solution().moveZeroes([0,1,0,3,12]))