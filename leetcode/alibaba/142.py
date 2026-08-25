from typing import Optional


class ListNode:
    def __init__(self, x):
        self.val = x
        self.next = None

class Solution:
    def detectCycle(self, head: Optional[ListNode]) -> Optional[ListNode]:
        seen = {}
        while head:
            if head in seen:
                return head
            else:
                seen.add(head)
                head = head.next
        return None