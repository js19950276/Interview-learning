from typing import List


class Solution:
    def subsets(self, nums: List[int]) -> List[List[int]]:
        res = []
        def backtrace(sub_nums, sub_res):
            if len(sub_res) < len(nums):
                sub_res = sorted(sub_res)
                if sub_res not in res:
                    res.append(sub_res)
            else:
                return
            for i in range(len(sub_nums)):
                backtrace(sub_nums[:i] + sub_nums[i+1:], sub_res + [sub_nums[i]])
        backtrace(nums, [])
        res.append(nums)
        return list(res)

if __name__ == '__main__':
    a = Solution().subsets(nums =[1,2,3])
    print(a)