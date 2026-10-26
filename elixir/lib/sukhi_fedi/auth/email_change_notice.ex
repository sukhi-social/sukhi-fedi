# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Auth.EmailChangeNotice do
  @moduledoc """
  The quiet heads-up for a swapped address: when an account moves from
  one *verified* address to another, one plain mail goes to the old
  one. If someone hijacked the session, the real owner's mailbox is
  where they find out — the new address, by design, is not the place.

  Only a previously verified address is written to. An unverified one
  was never proven to belong to the account, so mailing it would just
  tell a stranger's mailbox that an account exists.

  Like `LoginNotice` this is a courtesy after the fact, not a gate: a
  failed send never undoes the change.
  """

  alias SukhiFedi.{Mailer, Schema.Account}

  @doc """
  `before` is the account as it was before the change, `after` the
  updated one. Answers `:ok` also when nothing needed sending.
  """
  @spec deliver(Account.t(), Account.t()) :: :ok | {:error, term()}
  def deliver(
        %Account{email: old, email_verified_at: %DateTime{}, username: username},
        %Account{email: new}
      )
      when is_binary(old) and old != new do
    Mailer.deliver(old, subject(), body(username, new))
  end

  def deliver(%Account{}, %Account{}), do: :ok

  defp subject do
    "[#{domain()}] メールアドレスが変更されました / 이메일 주소가 변경되었어요"
  end

  defp body(username, new_email) do
    greeting =
      case username do
        nil -> ""
        name -> "@#{name} さん / @#{name} 님\n\n"
      end

    """
    #{greeting}#{domain()} のアカウントのメールアドレスが、つぎのものに変更されました。
    #{domain()} 계정의 이메일 주소가 다음 주소로 변경되었어요.

        #{mask(new_email)}

    心当たりがあれば、なにもしなくて大丈夫です。
    짚이는 데가 있다면, 아무것도 하지 않아도 괜찮아요.

    もし心当たりがなければ、ログインと安全のページで、ログイン中の
    端末と認証方法を見直してください。
    만약 짚이는 데가 없다면, 로그인과 안전 페이지에서 로그인 중인
    기기와 인증 방법을 살펴봐 주세요.

        https://#{domain()}/settings/security
    """
  end

  # `ab***@example.test` — enough to recognise it, not enough to hand a
  # full address to whoever reads the old mailbox.
  @doc false
  @spec mask(String.t()) :: String.t()
  def mask(email) do
    case String.split(email, "@", parts: 2) do
      [local, host] -> String.slice(local, 0, 2) <> "***@" <> host
      _ -> "***"
    end
  end

  defp domain, do: Application.get_env(:sukhi_fedi, :domain, "localhost:4000")
end
