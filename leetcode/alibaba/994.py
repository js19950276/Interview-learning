from typing import List


class Solution:
    def orangesRotting(self, grid: List[List[int]]) -> int:
        res = 0
        fresh = 0
        stack = []
        for row in range(len(grid)):
            for col in range(len(grid[0])):
                if grid[row][col] == 2:
                    stack.append((row,col))
                if grid[row][col] == 1:
                    fresh += 1

        if not stack:
            return 0

        while stack:
            for _ in range(len(stack)):
                row, col = stack.pop(0)
                for i, j in [[row + 1, col],[row - 1, col],[row, col + 1],[row, col - 1]]:
                    if 0 <= i < len(grid) and 0 <= j < len(grid[0]) and grid[i][j] == 1:
                        stack.append((i,j))
                        grid[i][j] = "2"
                        fresh -= 1
            res += 1

        return -1 if fresh else res - 1

if __name__ == '__main__':
    s = Solution()
    grid = [[2,1,1],
            [0,1,1],
            [1,0,1]]

    print(s.orangesRotting(grid))