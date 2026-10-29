from typing import List


class Solution:
    def searchMatrix(self, matrix: List[List[int]], target: int) -> bool:
        top, bottom = 0, len(matrix) - 1
        while top < bottom:
            mid = (top + bottom) // 2
            if matrix[mid][-1] == target:
                return True
            elif matrix[mid][-1] > target:
                bottom = mid
            else:
                top = mid + 1

        left, right = 0, len(matrix[0]) - 1
        while left <= right:
            mid = (left + right) // 2
            if matrix[top][mid] == target:
                return True
            elif matrix[top][mid] < target:
                left = mid + 1
            else:
                right = mid - 1
        else:
            return False

if __name__ == '__main__':
    a = Solution().searchMatrix([[1,3,5,7],[10,11,16,20],[23,30,34,50]], 10)
    print(a)