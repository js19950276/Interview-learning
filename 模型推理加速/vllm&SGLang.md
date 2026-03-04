* vllm
  * pagedAttention —— 像操作系统分页一样管理 KV Cache
    * 核心思想：把 KV Cache 当成虚拟内存来分页管理，不再要求连续存储。
    * 把每个序列的 KV Cache 切成固定大小的 block（页），通常 16 token / block（可调）
    * 这些 block 物理上可以不连续，放在显存的任何空闲位置
    * 每个序列用一个 块表（block table） 来记录：第几层 → 第几个 block 的物理位置
    * 需要计算 attention 时，通过块表找到对应的物理 block 地址
  * Continuous Batching —— 让 GPU 像流水线一样不间断工作
    * 传统静态批处理：
      * 凑够 N 个请求 → 一起 prefill → 一起 decode → 全部生成完 才接受新请求
      * 最长的那个请求会卡住所有人，GPU 经常空闲
    * Continuous Batching（迭代级调度）：
      * 每一层（每个 decoding step）都重新动态组批
      * 已经生成结束的序列立刻被剔除
      * 新进来的请求（哪怕是 prefill）立刻插入空位
      * GPU 几乎一直在满载运行
    * vLLM 的具体做法：
      * prefill 和 decode 分开调度（一个 step 要么全 prefill，要么全 decode）
      * decode 阶段使用定制的 PagedAttention CUDA 内核（融合了所有 attention 计算）
      * prefill 阶段借用 xformers 或 flash-attention（计算密集）
      * 这样实现简单，性能却非常好
  * 总结
    * pagedAttention显存利用率更高了，共享前缀，但是block里的token数是固定的，所以可能下一个对话拿到的不是全部的kv cache，有可能只拿到整数倍
    * Continuous Batching就是动态组batch，一个batch里的query decode完了，直接踢出，换新的query进来decode
* SGLang
  * RadixAttention（基数树/前缀树管理）
    * KV Cache 本质上只依赖前缀 token
        * Transformer 的 self-attention 中，某个位置的 Key/Value 只取决于它之前的所有 token（包括自己）。所以只要两个请求的前缀 token 序列完全相同，后面的 KV Cache 就可以直接复用，无需重新算 prefill。
    * 传统方式的局限（vLLM 等）
      * vLLM 的 Automatic Prefix Caching 主要依赖 block 级别的 hash + 前缀匹配。
      * 通常要求整块对齐（比如 16 token 一个 block），而且匹配粒度较粗。
      * 对不规则长度、部分重叠、树状分支（多轮对话中用户不同分支）支持较弱，需要手动配置或效果打折。
    * Radix Tree（基数树 / 压缩前缀树）的关键优势
      * Radix tree 是一种压缩过的 trie（前缀树），它的边可以携带多个连续 token（而非单个 token），极大压缩了树的高度和节点数。
        * 典型结构示例：
          * 根
            ├── "You are a helpful assistant."   (一整句作为一个边，KV cache 挂在这个节点)
            │   ├── " User: Hello!"              → 节点 A (存 Hello! 的 KV)
            │   │   ├── " Assistant: Hi there!"  → 节点 B
            │   │   └── " Assistant: Hey!"       → 节点 C (分支)
            │   └── " User: Tell me a joke."     → 另一个分支
            └── "You are Grok built by xAI."     (另一个常见系统提示)
          * 每个节点对应一段连续 token 序列 + 对应的 KV cache 页面（通常按 token 粒度分页）。
          * 前缀匹配：当新请求进来时，从根节点开始沿着树“走”，走得越远，匹配的前缀就越长。
          * 找到最长公共前缀（longest prefix match）后，直接接上那个节点的 KV cache，从不匹配的第一个 token 开始继续计算。
      * 配套机制让它真正“高效”
        * 自动前缀匹配 + 插入：前端总是发完整 prompt，后端自动在 radix tree 里找最长匹配 → 复用 → 插入新生成的部分（边可以动态拆分/合并）。
        * LRU 淘汰：优先淘汰最近最少使用的叶子节点，公共祖先能尽量保留（直到自己变成叶子才被淘汰）。
        * 引用计数：正在被 decode 的请求引用的节点不能淘汰，保证安全。
        * 与连续批处理兼容：prefill 时用匹配到的前缀 KV，decode 时正常追加。
        * 内存页粒度：KV cache 还是分页存储（类似 paged），但索引用树结构而非 hash map。
  * Zero-overhead CPU scheduler
    * 时间轴 →
      GPU:  [ Batch1 计算 ]          [ Batch2 计算 ]          [ Batch3 计算 ]
      CPU:           [准备 Batch2 元数据]          [准备 Batch3 元数据]
                     ↑ GPU 算 Batch1 时 CPU 空闲
                     ↑ GPU 空闲等 CPU 准备 Batch2
    * Zero-Overhead 调度
      GPU:  [ Batch N   ]   [ Batch N+1 ]   [ Batch N+2 ]   ...
      CPU:         [提前准备 Batch N+1 的所有元数据]   [提前准备 Batch N+2]   ...
                 ↑ CPU 在 GPU 算 Batch N 时，就把 Batch N+1 的 radix 匹配、block 分配、token 位置、attention metadata 等全准备好
                 ↑ GPU 算完 Batch N 立刻就能启动 Batch N+1，无等待
    * 提前一轮：CPU 不等当前 batch 算完结果，就开始为“下一个” batch 做准备