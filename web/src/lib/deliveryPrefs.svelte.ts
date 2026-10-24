// 配信の時系列(右下の枠)についての、この端末だけの好み。
//
//   off        そもそも出さない(設定の「表示しない」)
//   collapsed  出ているあいだ、たたんで小さな札にする(枠の「隠す / 開く」)
//
// サーバには置かない。画面の好みで、端末ごとに違ってよいから。localStorage が
// 使えない場所(プライベート窓など)では、このページを開いているあいだだけ覚える。

const KEY = { off: 'sukhi.delivery.off', collapsed: 'sukhi.delivery.collapsed' } as const;

function read(key: string): boolean {
  try {
    return localStorage.getItem(key) === '1';
  } catch {
    return false;
  }
}

function write(key: string, on: boolean) {
  try {
    if (on) localStorage.setItem(key, '1');
    else localStorage.removeItem(key);
  } catch {
    // 覚えられなくても、いまの画面では効く。
  }
}

export const deliveryPrefs = $state({
  off: typeof localStorage === 'undefined' ? false : read(KEY.off),
  collapsed: typeof localStorage === 'undefined' ? false : read(KEY.collapsed)
});

export function setDeliveryOff(on: boolean) {
  deliveryPrefs.off = on;
  write(KEY.off, on);
}

export function setDeliveryCollapsed(on: boolean) {
  deliveryPrefs.collapsed = on;
  write(KEY.collapsed, on);
}
