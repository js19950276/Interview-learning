class Solution:
    def twoSum(self, nums: list[int], target: int) -> list[int]:
        map = dict()
        for i, v in enumerate(nums):
            if v in map:
                return [map[v], i]
            map[target - v] = i
        else:
            return []

if __name__ == '__main__':
    sol = Solution()
    print(sol.twoSum([2, 7, 11, 15], 9))