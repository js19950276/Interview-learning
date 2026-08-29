# RunCommand 工具演示
import datetime

def show_time():
    now = datetime.datetime.now()
    return now.strftime("%Y-%m-%d %H:%M:%S")

if __name__ == "__main__":
    print(f"当前时间: {show_time()}")
