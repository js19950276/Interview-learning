# Definition for singly-linked list.
from typing import Optional


class ListNode:
    def __init__(self, x):
        self.val = x
        self.next = None

class Solution:
    def getIntersectionNode(self, headA: ListNode, headB: ListNode) -> Optional[ListNode]:
        tmp = set()
        while headA:
            tmp.add(headA)
            headA = headA.next

        while headB:
            if headB in tmp:
                return headB
            headB = headB.next

        return None