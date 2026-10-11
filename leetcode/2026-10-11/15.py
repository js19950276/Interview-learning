class Solution:
    def threeSum(self, nums: list[int]) -> list[list[int]]:
        nums.sort()
        res = []
        for i, v in enumerate(nums):
            if v > 0:
                break
            if i > 0 and nums[i - 1] == v:
                continue
            left, right = i + 1, len(nums) - 1
            while left < right:
                if nums[left] + nums[right] + v == 0:
                    tmp = [v, nums[left], nums[right]]
                    if tmp not in res:
                        res.append(tmp)
                    left += 1
                    right -= 1
                elif nums[left] + nums[right] + v < 0:
                    left += 1
                else:
                    right -= 1

        return res

if __name__ == '__main__':
    nums = [-1, 0, 1, 2, -1, -4]
    print(Solution().threeSum(nums))