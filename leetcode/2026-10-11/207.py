class Solution:
    def canFinish(self, numCourses: int, prerequisites: list[list[int]]) -> bool:
        prerequisites.sort(key=lambda x: (x[1], x[0]))
        course = set()
        for i, v in enumerate(prerequisites):
            if i == 0:
                course.add(v[0])
                course.add(v[1])
                continue
            if v[1] in course:
                if v[0] in course:
                    return False
                else:
                    course.add(v[0])
        else:
            return len(course) == numCourses



if __name__ == '__main__':
    s = Solution()
    s.canFinish(5, [[1,4],[2,4],[3,1],[3,2]])
