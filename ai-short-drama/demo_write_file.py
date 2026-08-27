# 本文件由 write_file 工具创建（write_file 用途：新建或整体覆盖一个文件）。


def demo_write_file(path, content):
    """演示如何把内容写入文件（write_file 风格说明）。

    write_file 工具的工作方式：
      - 以「整体覆盖」语义写入：若文件不存在则新建，若已存在则用
        新内容完全替换旧内容（而非追加）。
      - 会自动创建所需的父目录。
      - 写入完成后会校验落盘内容，返回结果中包含 verified 字段。

    本函数用标准库 open(..., 'w') 模拟同样的「整体写入」语义，
    以便离线演示 write_file 的核心行为。

    Args:
        path: 目标文件路径（字符串）。不存在则创建，已存在则覆盖。
        content: 要写入的完整文本内容（字符串）。

    Returns:
        dict: 模拟 write_file 的返回结构，形如
            {"path": path, "verified": True}。
    """
    # 'w' 模式 = 写入（整体覆盖）；encoding='utf-8' 保证中文等字符正确写入。
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    # write_file 在写入后会校验落盘内容；这里以 verified=True 模拟成功。
    return {"path": path, "verified": True}


if __name__ == "__main__":
    target = "demo_write_file_output.txt"
    result = demo_write_file(target, "Hello, write_file!\n这是一次整体写入演示。\n")
    print(f"写入完成：{result['path']}，是否创建成功（verified）：{result['verified']}")
