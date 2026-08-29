print("Hello, Trae!")
print("This is a test file.")

# 添加一些功能
name = "Trae"
print(f"Welcome, {name}!")


def demo_patch_capability():
    """演示 patch 工具的用途。"""
    print("patch 工具用于对已有文件做增量补丁修改，")
    print("它只精确替换匹配到的片段，不会重写整个文件，")
    print("非常适合做小范围、定位精确的改动。")


if __name__ == "__main__":
    demo_patch_capability()
