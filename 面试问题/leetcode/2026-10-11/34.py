class Solution:
    def searchRange(self, nums: list[int], target: int) -> list[int]:
        left, right = 0, len(nums)-1
        tmp_index = -1
        while left <= right:
            mid = (left+right)//2
            if nums[mid] == target:
                tmp_index = mid
                break
            elif nums[mid] < target:
                left = mid + 1
            else:
                right = mid - 1

        if tmp_index == -1:
            return [-1,-1]

        left, right = tmp_index - 1, tmp_index + 1
        while left >= 0:
            if nums[left] == target:
                left -= 1
            else:
                break

        while right < len(nums):
            if nums[right] == target:
                right += 1
            else:
                break

        return [left + 1, right-1]

if __name__ == '__main__':
    nums = [5,7,7,8,8,10]
    target = 8
    print(Solution().searchRange(nums, target))