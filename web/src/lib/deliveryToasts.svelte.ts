// 配信の時系列を、投稿の外 ── 画面の右下に出すための置き場。
//
// 投稿(Status)は、自分の投稿がどこまで出ていったかを知っている。けれど
// 見せる場所は、投稿の中ではなく、隅の小さな枠。置き場をひとつ挟んで、
// Status は「いまこう」と置くだけ、枠(DeliveryToasts)は並べるだけにする。
// 同じ投稿が二か所に出ていても、id で一枚にまとまる。

import { untrack } from 'svelte';

export type DeliveryToast = { id: string; at: number; percent: number | null; delayed: boolean };

export const deliveryToasts = $state<{ list: DeliveryToast[] }>({ list: [] });

// どちらも、Status の $effect の中から呼ばれる。ここで list を読むと、
// effect が list に依存して、書くたびに自分を呼び直す(止まらない)。
// 読みは untrack の中で。
export function putDeliveryToast(toast: DeliveryToast) {
  untrack(() => {
    const i = deliveryToasts.list.findIndex((t) => t.id === toast.id);
    if (i < 0) deliveryToasts.list.push(toast);
    else deliveryToasts.list[i] = toast;
  });
}

export function dropDeliveryToast(id: string) {
  untrack(() => {
    if (deliveryToasts.list.some((t) => t.id === id)) {
      deliveryToasts.list = deliveryToasts.list.filter((t) => t.id !== id);
    }
  });
}
