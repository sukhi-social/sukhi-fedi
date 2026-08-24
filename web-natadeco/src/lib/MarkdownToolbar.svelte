<script lang="ts">
  import { t } from '$lib/i18n.svelte';

  // 本文の欄に、太字・斜体・リンク・リスト・引用を差し込む小さな道具。
  // マークダウン自体はサーバー側がもう通している(Earmark)ので、ここは
  // 「打てば効く」を「押せば効く」にするだけ ── 構文を覚えなくていい
  // ように。
  let {
    value = $bindable(''),
    el
  }: {
    value?: string;
    el: HTMLTextAreaElement | null;
  } = $props();

  // 選んだ範囲を前後で挟む。選んでいなければ、placeholder ごと挟んで
  // その部分を選び直す ── 続けてそのまま打てる。
  function wrap(before: string, after: string, placeholder: string) {
    const ta = el;
    if (!ta) return;
    const start = ta.selectionStart ?? value.length;
    const end = ta.selectionEnd ?? value.length;
    const had = start !== end;
    const middle = had ? value.slice(start, end) : placeholder;

    value = value.slice(0, start) + before + middle + after + value.slice(end);

    const selStart = start + before.length;
    const selEnd = selStart + middle.length;
    requestAnimationFrame(() => {
      ta.focus();
      ta.setSelectionRange(selStart, selEnd);
    });
  }

  // 選んだ範囲にかかる行、一行ずつの頭に付ける(リスト・引用)。
  function prefixLines(prefix: string) {
    const ta = el;
    if (!ta) return;
    const start = ta.selectionStart ?? 0;
    const end = ta.selectionEnd ?? 0;
    const lineStart = value.lastIndexOf('\n', start - 1) + 1;
    const nl = value.indexOf('\n', end);
    const lineEnd = nl === -1 ? value.length : nl;
    const block = value.slice(lineStart, lineEnd);
    const prefixed = block
      .split('\n')
      .map((l) => prefix + l)
      .join('\n');

    value = value.slice(0, lineStart) + prefixed + value.slice(lineEnd);

    requestAnimationFrame(() => {
      ta.focus();
      ta.setSelectionRange(lineStart, lineStart + prefixed.length);
    });
  }

  // 見出しは、複数行にまたがらない(リスト・引用とはちがう) ──
  // カーソルのある一行だけに付ける。もう付いていたら外す(押し直せる)。
  function toggleHeading(prefix: string) {
    const ta = el;
    if (!ta) return;
    const start = ta.selectionStart ?? 0;
    const lineStart = value.lastIndexOf('\n', start - 1) + 1;
    const nl = value.indexOf('\n', lineStart);
    const lineEnd = nl === -1 ? value.length : nl;
    const line = value.slice(lineStart, lineEnd);
    const newLine = line.startsWith(prefix) ? line.slice(prefix.length) : prefix + line;

    value = value.slice(0, lineStart) + newLine + value.slice(lineEnd);

    const cursor = lineStart + newLine.length;
    requestAnimationFrame(() => {
      ta.focus();
      ta.setSelectionRange(cursor, cursor);
    });
  }
</script>

<div class="toolbar" role="toolbar">
  <button type="button" title={t().toolbar.heading} onclick={() => toggleHeading('## ')}> H </button>
  <button type="button" title={t().toolbar.bold} onclick={() => wrap('**', '**', t().toolbar.bold)}>
    <strong>B</strong>
  </button>
  <button type="button" title={t().toolbar.italic} onclick={() => wrap('*', '*', t().toolbar.italic)}>
    <em>I</em>
  </button>
  <button type="button" title={t().toolbar.link} onclick={() => wrap('[', '](url)', t().toolbar.link)}>
    🔗
  </button>
  <button type="button" title={t().toolbar.list} onclick={() => prefixLines('- ')}> • </button>
  <button type="button" title={t().toolbar.quote} onclick={() => prefixLines('> ')}> " </button>
</div>

<style>
  .toolbar {
    display: flex;
    gap: 0.3rem;
    margin-bottom: 0.3rem;
  }

  .toolbar button {
    background: var(--paper-raised);
    border: 1px solid var(--line);
    border-radius: var(--radius);
    width: 2rem;
    height: 2rem;
    display: grid;
    place-items: center;
    color: var(--ink-soft);
    cursor: pointer;
    font-size: 0.9rem;
    line-height: 1;
  }

  .toolbar button:hover {
    border-color: var(--sun);
    color: var(--ink);
  }
</style>
