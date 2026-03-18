from typing import List


class Solution:
    def findKthLargest(self, nums: List[int], k: int) -> int:
        print(nums)
        random_num = nums[0]

        small, equal, big = [], [], []
        for num in nums:
            if num > random_num:
                big.append(num)
            elif num < random_num:
                small.append(num)
            else:
                equal.append(num)

        if k <= len(big):
            return self.findKthLargest(big, k)
        elif k > len(big) + len(equal):
            return self.findKthLargest(small, k - len(small) - len(equal))
        else:
            return random_num

if __name__ == '__main__':
    a = [3, 2, 3, 1, 2, 4, 5, 5, 6]
    s = Solution().findKthLargest(a, 4)

