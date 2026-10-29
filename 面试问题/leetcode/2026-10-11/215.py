from typing import List


class Solution:
    def findKthLargest(self, nums: List[int], k: int) -> int:
        small, equal, large = [], [], []
        random_num = nums[0]
        for num in nums:
            if num > random_num:
                large.append(num)
            elif num == random_num:
                equal.append(num)
            else:
                small.append(num)

        if len(large) >= k:
            return self.findKthLargest(large, k)
        elif k > len(large) + len(equal):
            return self.findKthLargest(small, k - len(large) - len(equal))
        else:
            return random_num

if __name__ == '__main__':
    s = Solution()
    print(s.findKthLargest([3,2,3,1,2,4,5,5,6], 4))