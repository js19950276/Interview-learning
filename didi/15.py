class Solution:
    def threeSum(self, nums: list[int]) -> list[list[int]]:
        nums.sort()
        res = []
        for i in range(len(nums)-2):
            left, right = i+1, len(nums)-1
            if nums[i] + nums[left] + nums[right] == 0:
                res.append([nums[i], nums[left], nums[right]])
            elif nums[i] + nums[left] + nums[right] < 0:
                left += 1
            else:
                right -= 1
        return res