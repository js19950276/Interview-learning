class Solution:
    def permute(self, nums: list[int]) -> list[list[int]]:
        res = []
        def backtrace(nums, tmp):
            if nums == [] and tmp not in res:
                res.append(tmp)
            for i, num in enumerate(nums):
                backtrace(nums[:i] + nums[i+1:], tmp + [num])
        backtrace(nums, [])
        return res

if __name__ == '__main__':
    sol = Solution()
    print(sol.permute([1,2,3]))
