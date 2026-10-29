from typing import List


class Solution:
    def searchRange(self, nums: List[int], target: int) -> List[int]:
        left, right = 0, len(nums) - 1
        tmp_index = -1
        while left <= right:
            mid = (left + right) // 2
            if nums[mid] == target:
                tmp_index = mid
                break
            elif nums[mid] < target:
                left = mid + 1
            else:
                right = mid - 1
        if tmp_index == -1:
            return [-1, -1]

        left, right = tmp_index - 1, tmp_index + 1
        while True and left >= 0:
            if nums[left] == target:
                left -= 1
            else:
                break
        while True and right <= len(nums) - 1:
            if nums[right] == target:
                right += 1
            else:
                break

        return [left+1, right-1]

if __name__ == '__main__':
    nums = [2,2]
    target = 2
    a = Solution().searchRange(nums, target)
    print(a)


