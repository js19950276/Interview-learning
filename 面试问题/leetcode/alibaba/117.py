class Node:
    def __init__(self, val: int = 0, left: 'Node' = None, right: 'Node' = None, next: 'Node' = None):
        self.val = val
        self.left = left
        self.right = right
        self.next = next


class Solution:
    def connect(self, root: 'Node') -> 'Node':
        if not root:
            return None
        stack = [root]
        while stack:
            new_stack = []
            for i in range(len(stack)):
                if i == len(stack) - 1:
                    break
                stack[i].next = stack[i+1]
                if stack[i].left:
                    new_stack.append(stack[i].left)
                if stack[i].right:
                    new_stack.append(stack[i].right)
            stack = new_stack
        return root

