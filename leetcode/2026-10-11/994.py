from typing import List

class Solution:
    def orangesRotting(self, grid: List[List[int]]) -> int:
        fresh = 0
        stack = []
        for row in range(len(grid)):
            for col in range(len(grid[0])):
                if grid[row][col] == 2:
                    stack.append((row, col))
                if grid[row][col] == 1:
                    fresh += 1

        if not stack:
            return 0

        res = 0
        while stack:
            for _ in range(len(stack)):
                row, col = stack.pop()
                for r, c in [[row + 1, col], [row, col + 1], [row, col - 1], [row - 1, col]]:
                    if 0 <= r < len(grid) and 0 <= c < len(grid[0]) and grid[r][c] == 1:
                        stack.append((r, c))
                        grid[r][c] = 2
                        fresh -= 1
            res += 1

        return -1 if fresh else res - 1

if __name__ == '__main__':

    grid = [[2,1,1],
            [0,1,1],
            [1,0,1]]
    sol = Solution()
    res = sol.orangesRotting(grid)
    print(res)
