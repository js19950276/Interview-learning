from typing import List


class Solution:
    def numIslands(self, grid: List[List[str]]) -> int:
        res = 0
        col = len(grid[0])
        row = len(grid)
        for i in range(row):
            for j in range(col):
                if grid[i][j] == "1":
                    self.backtrace(grid, i, j, row, col)
                    res += 1
        return res

    def backtrace(self, grid, i, j, row, col):
        if i < 0 or j < 0 or i >= row or j >= col or grid[i][j] == "0":
            return
        grid[i][j] = "0"
        self.backtrace(grid, i+1, j, row, col)
        self.backtrace(grid, i-1, j, row, col)
        self.backtrace(grid, i, j+1, row, col)
        self.backtrace(grid, i, j-1, row, col)

if __name__ == '__main__':
    s = Solution()
    grid =[["1", "1", "1", "1", "0"],
           ["1", "1", "0", "1", "0"],
           ["1", "1", "0", "0", "0"],
           ["0", "0", "0", "0", "0"]]
    s.numIslands(grid)