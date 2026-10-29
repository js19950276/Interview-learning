from typing import List


class Solution:
    def setZeroes(self, matrix: List[List[int]]) -> None:
        """
        Do not return anything, modify matrix in-place instead.
        """
        row_list = []
        col_list = []
        for row in range(len(matrix)):
            for col in range(len(matrix[0])):
                if matrix[row][col] == 0:
                    row_list.append(row)
                    col_list.append(col)
        for row in range(len(matrix)):
            for col in range(len(matrix[0])):
                if row in row_list or col in col_list:
                    matrix[row][col] = 0
