# Definition for singly-linked list.
from typing import Optional


class ListNode:
    def __init__(self, x):
        self.val = x
        self.next = None

class Solution:
    def detectCycle(self, head: Optional[ListNode]) -> Optional[ListNode]:
        tmp = set()
        while head:
            if head.next in tmp:
                return head.next
            tmp.add(head)
            head = head.next
        return None