from typing import List


class Solution:
    def solve(self, board: List[List[str]]) -> None:
        """
        Do not return anything, modify board in-place instead.
        """
        def dfs(i, j):
            board[i][j] = "Y"
            for _i, _j in [[i+1, j], [i-1, j], [i, j-1], [i, j+1]]:
                if 0 <= _i < len(board) and 0 <= _j < len(board[0]) and board[_i][_j] == "O":
                    dfs(_i, _j)

        for i in [0, len(board) - 1]:
            for j in range(len(board[0])):
                if board[i][j] == "O":
                    dfs(i, j)

        for i in range(len(board)):
            for j in [0, len(board[0]) - 1]:
                if board[i][j] == "O":
                    dfs(i, j)

        for i in range(len(board)):
            for j in range(len(board[0])):
                if board[i][j] == "Y":
                    board[i][j] = "O"
                elif board[i][j] == "O":
                    board[i][j] = "X"

if __name__ == '__main__':
    a = [["X", "X", "X", "X"], ["X", "O", "O", "X"], ["X", "X", "O", "X"], ["X", "O", "X", "X"]]
    s = Solution().solve(a)
    print(a)