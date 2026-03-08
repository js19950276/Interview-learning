
class ListNode:
    def __init__(self, k=None, v=None):
        self.k = k
        self.v = v
        self.prev = None
        self.next = None


class LRUCache:

    def __init__(self, capacity: int):
        self.hashmap = {}
        self.head = ListNode()
        self.tail = ListNode()
        self.head.next = self.tail
        self.tail.prev = self.head

    def get(self, key: int) -> int:
        if key in self.hashmap:
            

            return self.hashmap[key].value
        else:
            return -1

    def put(self, key: int, value: int) -> None:
