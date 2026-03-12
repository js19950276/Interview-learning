# Definition for a binary tree node.
from typing import Optional, List


class TreeNode:
    def __init__(self, val=0, left=None, right=None):
        self.val = val
        self.left = left
        self.right = right

class Solution:
    def rightSideView(self, root: Optional[TreeNode]) -> List[int]:
        if not root:
            return []
        stack = [root]
        res = []
        while stack:
            sub_root = stack.pop()
            res.append(sub_root.val)
            new_stack = []
            for s in stack:
                if s.left:
                    new_stack.append(s.left)
                if s.right:
                    new_stack.append(s.right)
            stack = new_stack
        return res


