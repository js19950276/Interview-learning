from typing import Optional


class ListNode:
    def __init__(self, val=0, next=None):
        self.val = val
        self.next = next


class Solution:
    def removeNthFromEnd(self, head: Optional[ListNode], n: int) -> Optional[ListNode]:
        dummy = ListNode(0, head)
        first = head
        second = dummy
        length = 0
        while first:
            length += 1
            first = first.next

        for i in range(length - n):
            second = second.next

        second.next = second.next.next
        return dummy.next