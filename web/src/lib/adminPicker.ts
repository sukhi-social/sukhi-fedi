// 管理画面の入口に並べるアカウント候補の組み立て。
//
// いま見ている人(me)は role を持っているが、他に一度ログインした
// アカウントは token しか無い。候補を出すには、ひとりずつ
// verify_credentials で引き直して role を見る ── この組み立てを、
// 設定ページとナビの両方が同じ形で使えるようにここへ置く。
//
// 強調(emphasized)されるのは role が admin の人だけ。条件は
// api.ts の isAdmin 一箇所に従う。
import { isAdmin, type Account } from './api';
import { loadOtherAccounts, resolveAccount } from './auth';

export type AdminChoice = {
  acct: string;
  display_name: string;
  avatar: string | null;
  token: string;
  emphasized: boolean;
};

export async function loadAdminChoices(current: Account, token: string): Promise<AdminChoice[]> {
  const others = await Promise.all(
    loadOtherAccounts().map(async (o): Promise<AdminChoice | null> => {
      const r = await resolveAccount(o.token);
      if (!r) return null;
      return {
        acct: r.acct,
        display_name: r.display_name,
        avatar: r.avatar,
        token: o.token.access_token,
        emphasized: isAdmin(r.role)
      };
    })
  );

  return [
    {
      acct: current.acct,
      display_name: current.display_name,
      avatar: current.avatar,
      token,
      emphasized: isAdmin(current.role?.name)
    },
    // いま見ている人が sf.accounts にも残っていた場合の二重を、読む側で
    // 黙って畳む(each_key_duplicate で画面を落とさない)。
    ...others.filter((a): a is AdminChoice => a !== null && a.acct !== current.acct)
  ];
}

// 候補の中に admin がひとりでもいるか。入口を出すかどうかの判定。
export function hasAdmin(choices: AdminChoice[]): boolean {
  return choices.some((a) => a.emphasized);
}
