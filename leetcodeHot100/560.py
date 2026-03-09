from typing import List


class Solution:
    def subarraySum(self, nums: List[int], k: int) -> int:
        res = 0
        tmp = [0]
        for i in range(len(nums) - 1):
            tmp.append(nums[i] + tmp[i])

        print(tmp)

        for i in range(len(nums)):
            for j in range(i, len(nums)):
                if tmp[j] - tmp[i] == k:
                    res += 1
        return res

if __name__ == '__main__':
    a = Solution().subarraySum(nums = [1,1,1], k = 2)
    print(a)


