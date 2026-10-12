class Solution:
    def decodeString(self, s: str) -> str:
        stack = []
        res = ""
        digit = 0
        tmp = ""
        for char in s:
            if char.isdigit():
                digit = digit*10 + int(char)
            elif char == "[":
                stack.append(digit)
                stack.append(tmp)
                tmp, digit = "", 0
            elif char == "]":
                _s = stack.pop()
                time = stack.pop()
                res += _s * time
            else:
                tmp += char
        return res

if __name__ == '__main__':
    s = Solution()
    print(s.decodeString("3[a2[c]]"))