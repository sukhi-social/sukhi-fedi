// 本文の書きやすさのための、小さな action 二つ。

/** 打った分だけ縦に伸びる。小さい箱の中で自分の書いたものを
 * スクロールして見返さなくていいように。 */
export function autoresize(node: HTMLTextAreaElement) {
  const resize = () => {
    node.style.height = 'auto';
    node.style.height = `${node.scrollHeight}px`;
  };
  resize();
  node.addEventListener('input', resize);
  return {
    destroy() {
      node.removeEventListener('input', resize);
    }
  };
}

/** Cmd/Ctrl+Enter で送信。マウスまで手を伸ばさなくていいように。 */
export function submitOnMetaEnter(node: HTMLTextAreaElement) {
  const onKeydown = (e: KeyboardEvent) => {
    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
      e.preventDefault();
      node.form?.requestSubmit();
    }
  };
  node.addEventListener('keydown', onKeydown);
  return {
    destroy() {
      node.removeEventListener('keydown', onKeydown);
    }
  };
}
