class Solution:
    def isPalindrome(self, s: str) -> bool:
        tmp = ""
        for _s in s:
            if "a" <= _s.lower() <= "z":
                tmp += _s.lower()
            if "0" <= _s <= "9":
                tmp += _s
        return tmp == tmp[::-1]