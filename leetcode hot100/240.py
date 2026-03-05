from typing import List


class Solution:
    def searchMatrix(self, matrix: List[List[int]], target: int) -> bool:
        left, right, top, bottom = 0, len(matrix[0]) - 1, 0, len(matrix) - 1
        while left <= right and top <= bottom:
            if matrix[top][right] == target:
                return True

            if matrix[top][right] > target:
                right -= 1
                continue

            if matrix[top][right] < target:
                top += 1
                continue
        return False

if __name__ == '__main__':
    matrix = [[-5]]
    target = -5
    print(Solution().searchMatrix(matrix, target))