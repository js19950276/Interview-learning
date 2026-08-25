from typing import List, Optional


class TreeNode:
    def __init__(self, val=0, left=None, right=None):
        self.val = val
        self.left = left
        self.right = right

class Solution:
    def buildTree(self, inorder: List[int], postorder: List[int]) -> Optional[TreeNode]:
        if not inorder or not postorder:
            return None
        res = TreeNode(postorder[-1])
        tmp = postorder[-1]
        index = inorder.index(tmp)

        res.left = self.buildTree(inorder[:index], postorder[:len(inorder[:index])])
        res.right = self.buildTree(inorder[index + 1:], postorder[len(inorder[:index]):len(postorder)-1])

        return res