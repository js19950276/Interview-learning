class Solution:
    def subsets(self, nums: list[int]) -> list[list[int]]:
        res = []
        def backtrack(nums, tmp):
            print(nums, tmp)
            if tmp not in res:
                res.append(tmp)
            for i in range(len(nums)):
                backtrack(nums[:i]+nums[i+1:], tmp+[nums[i]])

        backtrack(nums, [])
        return res

if __name__ == '__main__':
    sol = Solution()
    print(sol.subsets([1,2,3]))
