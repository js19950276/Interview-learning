from typing import List


class Solution:
    def kSmallestPairs(self, nums1: List[int], nums2: List[int], k: int) -> List[List[int]]:

        res = [[nums1[0], nums2[0]]]
        k -= 1

        n1_index, n2_index = 0, 0
        while True:
            if nums1[n1_index + 1] + nums2[n2_index] > nums1[n1_index] + nums2[n2_index + 1]:
                res.append([nums1[n1_index], nums2[n2_index + 1]])
                n2_index += 1
            else:
                res.append([nums1[n1_index + 1], nums2[n2_index]])
                n1_index += 1
            k -= 1
            if k == 0 or n1_index == len(nums1) or n2_index == len(nums2):
                break

        return res

if __name__ == '__main__':
    nums1 = [1, 7, 11]
    nums2 = [2, 4, 6]
    s = Solution().kSmallestPairs(nums1, nums2, 3)
    print(s)