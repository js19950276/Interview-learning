import time
import streamlit as st
from agent.parser import parse_docx
from agent.hook_rewriter import rewrite_single_text
from agent.emotion_scorer import score_text
from agent.exporter import export_rewrite
from prompts.hook_rewrite import EMOTION_TYPES


st.set_page_config(page_title="短剧钩子重构 Agent", page_icon="🎬", layout="wide")
st.title("🎬 短剧钩子重构 Agent")
st.caption("上传 Word 剧本 → 选择情绪变体 → 钩子重构 → 评分 → 下载 Word")

uploaded_file = st.file_uploader("上传剧本（.docx）", type=["docx"])

if uploaded_file is not None:
    script = parse_docx(uploaded_file)
    st.success(f"解析完成：**{script.title}**，共 {len(script.scenes)} 个场景")

    with st.expander("查看原始剧本", expanded=False):
        st.text(script.raw_text)

    options = [f"{et} — {ed}" for et, ed in EMOTION_TYPES]
    selected = st.selectbox("选择情绪变体", options)
    selected_idx = options.index(selected)
    emotion_type, emotion_desc = EMOTION_TYPES[selected_idx]

    if st.button("开始钩子重构", type="primary"):
        progress = st.progress(0, text="准备中...")
        t0 = time.time()

        # Step 1: 生成重构文本
        progress.progress(10, text=f"正在生成【{emotion_type}】变体...")
        result_text = rewrite_single_text(script.raw_text, emotion_type, emotion_desc)
        elapsed1 = time.time() - t0
        progress.progress(70, text=f"变体生成完成（{elapsed1:.1f}s），正在评分...")

        # Step 2: 情绪评分
        with st.spinner("正在进行情绪评分..."):
            sr = score_text(emotion_type, result_text)
        elapsed2 = time.time() - t0
        progress.progress(95, text=f"评分完成（{elapsed2:.1f}s），正在导出...")

        # Step 3: 导出
        doc_buf = export_rewrite(script.title, emotion_type, result_text)
        progress.progress(100, text=f"全部完成！总耗时 {time.time() - t0:.1f}s")

        st.session_state["result_text"] = result_text
        st.session_state["emotion_type"] = emotion_type
        st.session_state["script_title"] = script.title
        st.session_state["score_result"] = sr
        st.session_state["doc_buf"] = doc_buf

if st.session_state.get("score_result"):
    st.divider()
    sr = st.session_state["score_result"]
    emotion_type = st.session_state["emotion_type"]

    with st.container(border=True):
        st.subheader(f"【{emotion_type}】重构结果")

        st.markdown(st.session_state["result_text"])

        st.divider()

        col1, col2 = st.columns([1, 3])
        with col1:
            st.metric("总分", f"{sr.total}/10")
        with col2:
            score_data = {k: [v] for k, v in sr.scores.items()}
            st.dataframe(score_data, hide_index=True)
        st.caption(sr.comment)

        st.download_button(
            label="下载重构剧本 Word 文档",
            data=st.session_state["doc_buf"],
            file_name=f"{st.session_state['script_title']}_{emotion_type}_重构.docx",
            mime="application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            type="primary",
        )
