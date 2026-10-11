class Solution:
    def merge(self, intervals: list[list[int]]) -> list[list[int]]:
        intervals.sort(key=lambda x: x[0])
        res = []
        for i, interval in enumerate(intervals):
            if i == 0:
                res.append(interval)
                continue
            if interval[1] < res[-1][1]:
                continue
            elif interval[0] > res[-1][1]:
                res.append(interval)
            else:
                res[-1][1] = interval[1]
        else:
            res.append(intervals)
