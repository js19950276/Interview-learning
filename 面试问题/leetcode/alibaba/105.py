# Definition for a binary tree node.
from typing import List, Optional


class TreeNode:
    def __init__(self, val=0, left=None, right=None):
        self.val = val
        self.left = left
        self.right = right

class Solution:
    def buildTree(self, preorder: List[int], inorder: List[int]) -> Optional[TreeNode]:
        if not preorder or not inorder:
            return
        res = TreeNode(preorder[0])
        tmp = preorder[0]
        index = inorder.index(tmp)


        res.left = self.buildTree(preorder[1:1+len(inorder[:index])], inorder[:index])
        res.right = self.buildTree(preorder[1+len(inorder[:index]):], inorder[index + 1:])
        return res

    def buildTree1(self, preorder: List[int], inorder: List[int]) -> Optional[TreeNode]:
        if not preorder or not inorder:
            return None
        root = TreeNode(preorder[0])
        left = inorder[:inorder.index(preorder[0])]
        right = inorder[inorder.index(preorder[0]) + 1:]

        root.left = self.buildTree(preorder[1:1 + len(left)], left)
        root.right = self.buildTree(preorder[1 + len(left):], right)

        return root