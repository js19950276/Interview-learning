# Definition for singly-linked list.
from typing import Optional


class ListNode:
    def __init__(self, x):
        self.val = x
        self.next = None

class Solution:
    def getIntersectionNode(self, headA: ListNode, headB: ListNode) -> Optional[ListNode]:
        headA_set = set()
        while headA:
            headA_set.add(headA)
            headA = headA.next

        while headB:
            if headB in headA_set:
                return headB
            else:
                headB = headB.next

        return None
