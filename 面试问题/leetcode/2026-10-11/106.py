# Definition for a binary tree node.
class TreeNode:
    def __init__(self, val=0, left=None, right=None):
        self.val = val
        self.left = left
        self.right = right

class Solution:
    def buildTree(self, inorder: list[int], postorder: list[int]) -> TreeNode:
        if not inorder or not postorder:
            return None
        print(inorder, postorder)
        root = TreeNode(postorder[-1])
        root_index = inorder.index(postorder[-1])
        root.left = self.buildTree(inorder[:root_index], postorder[:len(inorder[:root_index])])
        root.right = self.buildTree(inorder[root_index+1:], postorder[len(inorder[:root_index]):-2])
        return root

if __name__ == '__main__':
    preorder = [3, 9, 20, 15, 7]
    inorder = [9, 3, 15, 20, 7]
    root = Solution().buildTree(preorder, inorder)