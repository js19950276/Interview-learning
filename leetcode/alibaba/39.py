from typing import List


class Solution:
    def combinationSum(self, candidates: List[int], target: int) -> List[List[int]]:
        res = []
        def backtrace(candidates, tmp):
            if sum(tmp) == target:
                tmp.sort()
                if tmp not in res:res.append(tmp)
            if sum(tmp) > target:
                return
            for candidate in candidates:
                backtrace(candidates, tmp + [candidate])

        backtrace(candidates, [])
        return res

if __name__ == '__main__':
    candidates = [2, 3, 6, 7]
    target = 7
    a = Solution().combinationSum(candidates, target)
    print(a)