from typing import List

class Solution:
    def numIslands(self, grid: List[List[str]]) -> int:
        res = 0
        col, row = len(grid), len(grid[0])
        for i in range(col):
            for j in range(row):
                if grid[i][j] == "1":
                    self.dfs(i, j, grid)
                    res += 1
        return res

    def dfs(self, i, j, grid):
        if i < 0 or j < 0 or i > len(grid) - 1 or j > len(grid[0]) - 1 or grid[i][j] != "1":
            return
        grid[i][j] = "0"
        self.dfs(i+1, j, grid)
        self.dfs(i-1, j, grid)
        self.dfs(i, j+1, grid)
        self.dfs(i, j-1, grid)

if __name__ == '__main__':
    grid = [
        ['1', '1', '0', '0', '0'],
        ['1', '1', '0', '0', '0'],
        ['0', '0', '1', '0', '0'],
        ['0', '0', '0', '1', '1']
    ]
    print(Solution().numIslands(grid))