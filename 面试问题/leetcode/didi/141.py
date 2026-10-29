from typing import Optional


class ListNode:
    def __init__(self, x):
        self.val = x
        self.next = None

class Solution:
    def hasCycle(self, head: Optional[ListNode]) -> bool:
        tmp = set()
        while head:
            if head.next in tmp:
                return True
            tmp.add(head)
            head = head.next
        return False
