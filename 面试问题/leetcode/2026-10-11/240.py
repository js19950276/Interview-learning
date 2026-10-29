from typing import List


class Solution:
    def searchMatrix(self, matrix: List[List[int]], target: int) -> bool:
        top, down, left, right = 0, len(matrix)-1, 0, len(matrix[0])-1
        while top <= down and left <= right:
            if matrix[top][right] == target:
                return True
            elif matrix[top][right] < target:
                top += 1
            else:
                right -= 1
        return False

if __name__ == '__main__':
    matrix = [[1, 4, 7, 11, 15], [2, 5, 8, 12, 19], [3, 6, 9, 16, 22], [10, 13, 14, 17, 24], [18, 21, 23, 26, 30]]
    sol = Solution()
    ans = sol.searchMatrix(matrix, 5)
    print(ans)