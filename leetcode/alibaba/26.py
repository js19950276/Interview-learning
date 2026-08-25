from typing import List


class Solution:
    def removeDuplicates(self, nums: List[int]) -> int:

        last_num = nums[0]
        next_index = 0
        for i in range(1, len(nums)):
            if nums[i] == last_num:
                continue
            else:
                next_index += 1
                nums[next_index] = nums[i]
                last_num = nums[i]
        if next_index < len(nums):
            nums[next_index+1:] = []
        return len(nums)
