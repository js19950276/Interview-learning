class Solution:
    def rotate(self, matrix: list[list[int]]) -> None:
        """
        Do not return anything, modify matrix in-place instead.
        """
        for i in range(len(matrix)):
            for j in range(i, len(matrix[0])):
                matrix[i][j], matrix[j][i] = matrix[j][i], matrix[i][j]

        for m in matrix:
            m.reverse()

        print(matrix)

if __name__ == '__main__':
    array = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
    Solution().rotate(array)