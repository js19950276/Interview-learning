from typing import List


class Solution:
    def merge(self, intervals: List[List[int]]) -> List[List[int]]:
        intervals.sort(key=lambda x:x[0])
        res = []
        for i, interval in enumerate(intervals):
            if i == 0:
                res.append(interval)
                continue
            if interval[0] > res[-1][1]:
                res.append(interval)
            else:
                if interval[1] <= res[-1][1]:
                    continue
                else:
                    res[-1][1] = max(res[-1][1], interval[1])
        else:
            return res