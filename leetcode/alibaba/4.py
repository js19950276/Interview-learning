from typing import List


class Solution:
    def findMedianSortedArrays(self, nums1: List[int], nums2: List[int]) -> float:
        # 始终在较短的数组上二分，复杂度 O(log(min(m, n)))
        if len(nums1) > len(nums2):
            nums1, nums2 = nums2, nums1
        m, n = len(nums1), len(nums2)

        # 分割线：nums1 左半取 i 个，nums2 左半取 j 个，左半共 total_left 个
        # （总数为奇数时，中位数就是左半的最大值，所以左边多放一个）
        total_left = (m + n + 1) // 2

        lo, hi = 0, m
        while lo <= hi:
            i = (lo + hi) // 2
            j = total_left - i
            # 分割线贴边时用正负无穷代替，保证比较永远合法
            nums1_left = nums1[i - 1] if i > 0 else float('-inf')
            nums1_right = nums1[i] if i < m else float('inf')
            nums2_left = nums2[j - 1] if j > 0 else float('-inf')
            nums2_right = nums2[j] if j < n else float('inf')

            if nums1_left <= nums2_right and nums2_left <= nums1_right:
                # 分割线合法：左半任意元素 <= 右半任意元素
                if (m + n) % 2 == 1:
                    return float(max(nums1_left, nums2_left))
                return (max(nums1_left, nums2_left) + min(nums1_right, nums2_right)) / 2
            elif nums1_left > nums2_right:
                hi = i - 1  # nums1 左边取多了，分割线左移
            else:
                lo = i + 1  # nums1 左边取少了，分割线右移
        return 0.0
