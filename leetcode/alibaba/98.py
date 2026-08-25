import math
from typing import Optional


class TreeNode:
    def __init__(self, val=0, left=None, right=None):
        self.val = val
        self.left = left
        self.right = right

class Solution:
    def isValidBST(self, root: Optional[TreeNode]) -> bool:
        def dfs(root, left, right):
            if not root:
                return True
            elif not (left < root.val < right):
                return False
            else:
                return dfs(root.left, left, root.val) and dfs(root.right, root.val, right)
        return dfs(root, -math.inf, math.inf)