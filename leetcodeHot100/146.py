
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
        self.capacity = capacity

    def get(self, key: int) -> int:
        if key in self.hashmap:
            value = self.hashmap[key].value
            value.prev.next = value.next
            value.next.prev = value.prev

            value.prev = self.tail.prev
            value.next = self.tail
            self.tail.prev.next = value
            self.tail.prev = value
            return value.v
        else:
            return -1

    def put(self, key: int, value: int) -> None:
        tmp = ListNode(key, value)
        if len(self.hashmap) < self.capacity:

            tmp.prev = self.tail.prev
            self.tail.prev.next = tmp
            self.tail.prev = tmp
            tmp.next = self.tail

            self.hashmap[key] = tmp
        else:
            self.head.next.prev = self.head
            self.head.next = self.head.next.next
            self.hashmap.pop(self.head.next.k)

            tmp.prev = self.tail.prev
            tmp.next = self.tail
            self.tail.prev.next = tmp
            self.tail.prev = tmp

            self.hashmap[key] = tmp
