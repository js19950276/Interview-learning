class Solution:
    def setZeroes(self, matrix: list[list[int]]) -> None:
        """
        Do not return anything, modify matrix in-place instead.
        """
        i, j = [], []
        for row in range(len(matrix)):
            for col in range(len(matrix[0])):
                if matrix[row][col] == 0:
                    i.append(col)
                    j.append(i)

        for row in range(len(matrix)):
            for col in range(len(matrix[0])):
                if row in i or col in j:
                    matrix[row][col] = 0

