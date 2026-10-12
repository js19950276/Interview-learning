class Solution:
    def findMin(self, nums: list[int]) -> int:
        left, right = -1, len(nums) - 1
        while left + 1< right:
            mid = (left + right) // 2
            if nums[mid] < nums[-1]:
                right = mid
            else:
                left = mid
        return nums[right]

if __name__ == '__main__':
    nums = [3,4,5,1,2]

    print(Solution().findMin(nums))