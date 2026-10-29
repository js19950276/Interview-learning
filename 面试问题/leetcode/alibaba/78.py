from typing import List

class Solution:
    def subsets(self, nums: List[int]) -> List[List[int]]:
        self.res = []
        self.backtrack([], 0, nums)
        return self.res

    def backtrack(self, sol, index, nums):
        print(sol, index, nums)
        if index == len(nums):
            self.res.append(sol)
            return

        self.backtrack(sol + [nums[index]], index + 1, nums)
        self.backtrack(sol, index + 1, nums)

if __name__ == '__main__':
    a = Solution().subsets(nums =[1,2,3])
    print(a)