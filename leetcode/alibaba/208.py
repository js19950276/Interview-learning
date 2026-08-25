class Node:
    def __init__(self):
        self.son = {}
        self.end = False

class Trie:

    def __init__(self):
        self.root = Node()

    def insert(self, word: str) -> None:
        dummy = self.root
        for w in word:
            if w not in dummy.son:
                dummy.son[w] = Node()
            dummy = dummy.son[w]
        dummy.end = True

    def search(self, word: str) -> bool:
        return self.find(word) == 2

    def startsWith(self, prefix: str) -> bool:
        return self.find(prefix) != 0

    def find(self, word: str) -> int:
        dummy = self.root
        for w in word:
            if w not in dummy.son:
                return 0
            dummy = dummy.son[w]
        if dummy.end:
            return 2
        return 1