# Definition for a binary tree node.
class TreeNode:
    def __init__(self, val=0, left=None, right=None):
        self.val = val
        self.left = left
        self.right = right

class Solution:
    def maxDepth(self, root: TreeNode) -> int:
        res = 0
        if not root:
            return res
        stack = [root]
        while stack:
            res += 1
            for _ in range(len(stack)):
                sub_root = stack.pop(0)
                if sub_root.left:
                    stack.append(sub_root.left)
                if sub_root.right:
                    stack.append(sub_root.right)
        return res
