from typing import Optional


class TreeNode:
    def __init__(self, val=0, left=None, right=None):
        self.val = val
        self.left = left
        self.right = right

class Solution:
    def isSymmetric(self, root: Optional[TreeNode]) -> bool:
        if not root:
            return True

    def isSame(self, left: Optional[TreeNode], right: Optional[TreeNode]):
        if not left or not right:
            return left == right
        return left.val == right.val and self.isSame(left.left, right.right) and self.isSame(left.right, right.left)