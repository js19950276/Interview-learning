class Solution:
    def insert(self, intervals: list[list[int]], newInterval: list[int]) -> list[list[int]]:
        intervals.append(newInterval)
        intervals = self.merge(intervals)
        return intervals


    def merge(self, intervals: list[list[int]]) -> list[list[int]]:
        res = []
        intervals.sort(key=lambda x: x[0])
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
            return res