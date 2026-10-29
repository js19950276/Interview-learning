class Solution:
    def insert(self, intervals: list[list[int]], newInterval: list[int]) -> list[list[int]]:
        intervals.sort(key=lambda x: x[0])
        for index, interval in enumerate(intervals):
            