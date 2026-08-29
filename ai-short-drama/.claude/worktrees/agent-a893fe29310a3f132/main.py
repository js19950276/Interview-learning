# This is a sample Python script.
import logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

# Press ⌃R to execute it or replace it with your code.
# Press Double ⇧ to search everywhere for classes, files, tool windows, actions, and settings.


# 打印问候语并记录调用日志
def print_hi(name):
    # Use a breakpoint in the code line below to debug your script.
    # 记录函数入参，便于排查调用来源
    logging.info(f'print_hi called with name={name}')
    print(f'Hi, {name}')  # Press ⌘F8 to toggle the breakpoint.
    logging.info('print_hi finished')

# Press the green button in the gutter to run the script.
if __name__ == '__main__':
    print_hi('PyCharm')

# See PyCharm help at https://www.jetbrains.com/help/pycharm/
