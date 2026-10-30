class Solution:
    def simplifyPath(self, path: str) -> str:
        paths = path.split('/')
        res = []
        for p in paths:
            if p == '..':
                if res: res.pop()
            elif p == '.' or not p:
                continue
            else:
                res.append(p)
        return '/' + '/'.join(res)

if __name__ == '__main__':
    solution = Solution()
    print(solution.simplifyPath('/home//foo/'))