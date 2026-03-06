import copy
from typing import List


class Solution:
    def exist(self, board: List[List[str]], word: str) -> bool:
        res = []
        def backtrace(direction, subword, usedDirection):
            if not subword:
                res.append(True)
                return
            for d in direction:
                i, j = d
                sub_direction = []
                sub_usedDirection = copy.deepcopy(usedDirection)
                if board[i][j] == subword[0] and d not in usedDirection:
                    if i + 1 < len(board) and [i+1, j] not in usedDirection:
                        sub_direction.append([i+1, j])
                    if i - 1 >= 0 and [i-1, j] not in usedDirection:
                        sub_direction.append([i-1, j])
                    if j + 1 < len(board[0]) and [i, j+1] not in usedDirection:
                        sub_direction.append([i, j+1])
                    if j - 1 >= 0 and [i, j-1] not in usedDirection:
                        sub_direction.append([i, j-1])
                    sub_usedDirection.append(d)
                    backtrace(sub_direction, subword[1:], sub_usedDirection)
            # print(res)
        for i in range(len(board)):
            for j in range(len(board[0])):
                if board[i][j] == word[0]:
                    usedDirection = [[i, j]]
                    sub_direction = []
                    if i + 1 < len(board):
                        sub_direction.append([i+1, j])
                    if i - 1 >= 0:
                        sub_direction.append([i-1, j])
                    if j + 1 < len(board[0]):
                        sub_direction.append([i, j+1])
                    if j - 1 >= 0:
                        sub_direction.append([i, j-1])
                    backtrace(sub_direction, word[1:], usedDirection)
        return any(res)


if __name__ == '__main__':
    board = [["A","B","C","E"],
             ["S","F","E","S"],
             ["A","D","E","E"]]
    word = "ABCESEEEFS"
    a = Solution().exist(board, word)
    print(a)