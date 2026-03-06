from inspect import stack
from typing import Optional, List


class TreeNode:
    def __init__(self, val=0, left=None, right=None):
        self.val = val
        self.left = left
        self.right = right

class Solution:
    def levelOrder(self, root: Optional[TreeNode]) -> List[List[int]]:
        res = []
        if not root:
            return res
        stack = [root]
        while stack:
            sub_res = []
            for _ in range(len(stack)):
                sub_root = stack.pop(0)
                sub_res.append(sub_root.val)
                if sub_root.left:
                    stack.append(sub_root.left)
                if sub_root.right:
                    stack.append(sub_root.right)
            res.append(sub_res)
        return res

