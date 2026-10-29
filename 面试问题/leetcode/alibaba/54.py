from typing import List


class Solution:
    def spiralOrder(self, matrix: List[List[int]]) -> List[int]:
        left, right, top, bottom = 0, len(matrix[0]) - 1, 0, len(matrix) - 1
        res = []
        while top <= bottom or left <= right:
            for i in range(left, right+1):
                res.append(matrix[top][i])
            top += 1

            if top > bottom:
                break

            for i in range(top, bottom+1):
                res.append(matrix[i][right])
            right -= 1

            if right < left:
                break

            sub_res = []
            for i in range(left, right+1):
                sub_res.append(matrix[bottom][i])

            res.extend(sub_res[::-1])
            bottom -= 1

            if bottom < top:
                break

            sub_res = []
            for i in range(top, bottom+1):
                sub_res.append(matrix[i][left])
            res.extend(sub_res[::-1])
            left += 1

            if left > right:
                break
        return res

if __name__ == '__main__':
    a = Solution()
    matrix = [[1,2,3,4],
              [5,6,7,8],
              [9,10,11,12]]

    print(a.spiralOrder(matrix))
