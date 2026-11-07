# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.JoinApplications.Mail do
  @moduledoc """
  The two mails an application sends (docs/JOIN.md), in the language the
  person was reading.

  The receipt mail carries **only the receipt number** and the day —
  never what was written — because the address may be a stranger's. The
  edit-link mail goes out only after the person says they received the
  first one. A missing or unknown language gets the Japanese text; these
  are written, not machine-made (voice: docs/ENGLISH_VOICE.md).
  """

  alias SukhiFedi.Mailer

  @weekdays %{
    "ja" => ~w(月 火 水 木 金 土 日),
    "ko" => ~w(월 화 수 목 금 토 일),
    "en" => ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)
  }

  @doc "Send the receipt. `check` is a `CheckDay.t()`."
  @spec receipt(String.t(), String.t(), map(), String.t() | nil) :: :ok | {:error, term()}
  def receipt(to, receipt, check, lang) do
    lang = lang(lang)
    Mailer.deliver(to, receipt_subject(lang, receipt), receipt_body(lang, receipt, check))
  end

  @doc "Send the edit link."
  @spec edit_link(String.t(), String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def edit_link(to, receipt, key, lang) do
    lang = lang(lang)
    url = "https://#{domain()}/join/edit/#{key}"
    Mailer.deliver(to, edit_subject(lang, receipt), edit_body(lang, receipt, url))
  end

  @doc "`木曜日` / `목요일` / `Thursday`, for the page and the mail."
  @spec weekday_name(String.t() | nil, 1..7) :: String.t()
  def weekday_name(lang, weekday) do
    lang = lang(lang)
    name = @weekdays |> Map.fetch!(lang) |> Enum.at(weekday - 1)

    case lang do
      "ja" -> name <> "曜日"
      "ko" -> name <> "요일"
      "en" -> name
    end
  end

  defp lang(l) when l in ["ja", "ko", "en"], do: l
  defp lang(_), do: "ja"

  defp when_text("ja", check, lang),
    do: "#{weekday_name(lang, check.weekday)}(#{check.days_after}日後)"

  defp when_text("ko", check, lang),
    do: "#{weekday_name(lang, check.weekday)}(#{check.days_after}일 후)"

  defp when_text("en", check, lang),
    do:
      "#{weekday_name(lang, check.weekday)} (in #{check.days_after} #{plural(check.days_after)})"

  defp plural(1), do: "day"
  defp plural(_), do: "days"

  defp receipt_subject("ja", r), do: "[#{domain()}] 受付のメール(受付番号 #{r})"
  defp receipt_subject("ko", r), do: "[#{domain()}] 접수 메일 (접수 번호 #{r})"
  defp receipt_subject("en", r), do: "[#{domain()}] We received your note (no. #{r})"

  defp receipt_body("ja", r, check) do
    """
    お申し込み、ありがとうございます。

        受付番号: #{r}

    申し込みのページに、この番号が出ています。合っていたら「はい！」を押してください。

    確認するのは、#{when_text("ja", check, "ja")}です。そのあと、メールでお返しします。
    遅くても、一週間以内にお返しします。

    心当たりがなければ、このメールは、そっと捨ててください。
    """
  end

  defp receipt_body("ko", r, check) do
    """
    신청해 주셔서 고맙습니다.

        접수 번호: #{r}

    신청 페이지에 이 번호가 보입니다. 맞으면 「네!」를 눌러 주세요.

    확인하는 날은 #{when_text("ko", check, "ko")}입니다. 그 뒤에 메일로 답해 드립니다.
    늦어도 일주일 안에 답합니다.

    짚이는 데가 없다면, 이 메일은 그냥 버려 주세요.
    """
  end

  defp receipt_body("en", r, check) do
    """
    Thank you for writing to us.

        Receipt number: #{r}

    The same number is on the page you filled in. If it matches, press "Yes" there.

    We will look on #{when_text("en", check, "en")}, then answer by email.
    Within a week at the latest.

    If this isn't yours, you can quietly set this email aside.
    """
  end

  defp edit_subject("ja", r), do: "[#{domain()}] 申し込みを編集するリンク(受付番号 #{r})"
  defp edit_subject("ko", r), do: "[#{domain()}] 신청을 고치는 링크 (접수 번호 #{r})"
  defp edit_subject("en", r), do: "[#{domain()}] Link to edit your note (no. #{r})"

  defp edit_body("ja", r, url) do
    """
    受付番号 #{r} の申し込みを、書き直したくなったときのリンクです。

        #{url}

    お返事をお返しするまで、使えます。ほかの人には、見せないでくださいね。

    心当たりがなければ、このメールは、そっと捨ててください。
    """
  end

  defp edit_body("ko", r, url) do
    """
    접수 번호 #{r} 의 신청을 다시 쓰고 싶을 때 쓰는 링크입니다.

        #{url}

    답을 드릴 때까지 쓸 수 있습니다. 다른 사람에게는 보여 주지 말아 주세요.

    짚이는 데가 없다면, 이 메일은 그냥 버려 주세요.
    """
  end

  defp edit_body("en", r, url) do
    """
    This is the link for rewriting your note, number #{r}.

        #{url}

    It works until we have written back. Please keep it to yourself.

    If this isn't yours, you can quietly set this email aside.
    """
  end

  defp domain, do: Application.get_env(:sukhi_fedi, :domain, "localhost:4000")
end
