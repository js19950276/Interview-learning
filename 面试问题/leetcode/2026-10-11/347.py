import collections


class Solution:
    def topKFrequent(self, nums: list[int], k: int) -> list[int]:
        count = collections.Counter(nums)
        max_count = max(count.values())

        buckets = [[] for _ in range(max_count + 1)]
        for x, c in count.items():
            buckets[c].append(x)

        buckets.reverse()

        cnt = 0
        res = []
        for bucket in buckets:
            cnt += len(bucket)
            res.extend(bucket)
            if cnt == k:
                return res