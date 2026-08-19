from collections import defaultdict
from typing import List


class Solution:
    def groupAnagrams(self, strs: List[str]) -> List[List[str]]:
        map = defaultdict(list)
        for str in strs:
            sorted_str = ''.join(sorted(str))
            map[sorted_str].append(str)

        return map.values()