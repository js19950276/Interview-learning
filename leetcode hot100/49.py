from collections import defaultdict
from typing import List


class Solution:
    def groupAnagrams(self, strs: List[str]) -> List[List[str]]:
        str_map = defaultdict(list)
        for str in strs:
            sort_str = "".join(sorted(str))
            str_map[sort_str].append(str)
        return list(str_map.values())

if __name__ == '__main__':
    a = Solution()
    print(a.groupAnagrams(["eat", "tea", "tan", "ate", "nat", "bat"]))


