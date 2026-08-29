"""Singly linked list implementation with CRUD, iterator, and tests."""

from __future__ import annotations
from typing import Any, Iterator, Optional


class Node:
    """A single node in the linked list."""

    def __init__(self, value: Any, next_node: Optional["Node"] = None) -> None:
        self.value = value
        self.next = next_node

    def __repr__(self) -> str:
        return f"Node({self.value!r})"


class LinkedList:
    """A singly linked list supporting CRUD operations and iteration."""

    def __init__(self) -> None:
        self._head: Optional[Node] = None
        self._size: int = 0

    # ----- Create -----
    def append(self, value: Any) -> None:
        """Append a value to the end of the list."""
        new_node = Node(value)
        if self._head is None:
            self._head = new_node
        else:
            cur = self._head
            while cur.next is not None:
                cur = cur.next
            cur.next = new_node
        self._size += 1

    def prepend(self, value: Any) -> None:
        """Prepend a value to the start of the list."""
        self._head = Node(value, self._head)
        self._size += 1

    def insert(self, index: int, value: Any) -> None:
        """Insert a value at a given index."""
        if index < 0 or index > self._size:
            raise IndexError("insert index out of range")
        if index == 0:
            self.prepend(value)
            return
        prev = self._node_at(index - 1)
        prev.next = Node(value, prev.next)
        self._size += 1

    # ----- Read -----
    def get(self, index: int) -> Any:
        """Get the value at a given index."""
        return self._node_at(index).value

    def find(self, value: Any) -> int:
        """Return the first index of value, or -1 if not found."""
        for i, v in enumerate(self):
            if v == value:
                return i
        return -1

    def __len__(self) -> int:
        return self._size

    def __iter__(self) -> Iterator[Any]:
        cur = self._head
        while cur is not None:
            yield cur.value
            cur = cur.next

    def __repr__(self) -> str:
        return "LinkedList([" + ", ".join(repr(v) for v in self) + "])"

    # ----- Update -----
    def set(self, index: int, value: Any) -> None:
        """Set the value at a given index."""
        self._node_at(index).value = value

    # ----- Delete -----
    def remove_at(self, index: int) -> Any:
        """Remove and return the value at index."""
        if index < 0 or index >= self._size:
            raise IndexError("remove index out of range")
        if index == 0:
            assert self._head is not None
            removed = self._head.value
            self._head = self._head.next
        else:
            prev = self._node_at(index - 1)
            assert prev.next is not None
            removed = prev.next.value
            prev.next = prev.next.next
        self._size -= 1
        return removed

    def remove(self, value: Any) -> bool:
        """Remove the first occurrence of value. Returns True if removed."""
        idx = self.find(value)
        if idx < 0:
            return False
        self.remove_at(idx)
        return True

    def clear(self) -> None:
        """Remove all elements."""
        self._head = None
        self._size = 0

    # ----- Internal helpers -----
    def _node_at(self, index: int) -> Node:
        if index < 0 or index >= self._size:
            raise IndexError("index out of range")
        cur = self._head
        for _ in range(index):
            assert cur is not None
            cur = cur.next
        assert cur is not None
        return cur


# ----- Tests -----
def _run_tests() -> None:
    ll = LinkedList()
    assert len(ll) == 0
    ll.append(1)
    ll.append(2)
    ll.append(3)
    assert len(ll) == 3
    assert list(ll) == [1, 2, 3]
    ll.prepend(0)
    assert list(ll) == [0, 1, 2, 3]
    ll.insert(2, 99)
    assert list(ll) == [0, 1, 99, 2, 3]
    assert ll.get(2) == 99
    assert ll.find(99) == 2
    assert ll.find(404) == -1
    ll.set(2, 100)
    assert ll.get(2) == 100
    assert ll.remove_at(0) == 0
    assert list(ll) == [1, 100, 2, 3]
    assert ll.remove(100) is True
    assert ll.remove(404) is False
    assert list(ll) == [1, 2, 3]
    ll.clear()
    assert len(ll) == 0 and list(ll) == []
    print("All linked list tests passed.")


if __name__ == "__main__":
    _run_tests()
