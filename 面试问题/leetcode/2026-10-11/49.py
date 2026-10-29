from collections import defaultdict


class Solution:
    def groupAnagrams(self, strs: list[str]) -> list[list[str]]:
        map = defaultdict(list)
        for str in strs:
            new_str = ''.join(sorted(str))
            map[new_str].append(str)
        return list(map.values())