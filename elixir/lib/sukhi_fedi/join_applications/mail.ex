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

  alias SukhiFedi.JoinApplications.CheckDay
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

  @doc """
  The welcome: a one-time entry link (14 days) and the greeter's one line.
  Written to the name they gave, or plainly if they gave none. It does not
  say "reply to this mail" — mails go out from a no-reply address.
  """
  @spec welcome(String.t(), String.t() | nil, String.t(), String.t() | nil, String.t() | nil) ::
          :ok | {:error, term()}
  def welcome(to, call_name, key, note, lang) do
    lang = lang(lang)
    url = "https://#{domain()}/welcome/#{key}"
    Mailer.deliver(to, welcome_subject(lang), welcome_body(lang, call_name, note, url))
  end

  @doc """
  The gentle answer for "not this time". `reason` is the greeter's own
  words, shown as written, or nothing.
  """
  @spec decline(String.t(), String.t() | nil, String.t() | nil, String.t() | nil) ::
          :ok | {:error, term()}
  def decline(to, call_name, reason, lang) do
    lang = lang(lang)
    Mailer.deliver(to, decline_subject(lang), decline_body(lang, call_name, reason))
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

  # ── welcome / decline ────────────────────────────────────────────────────

  defp greeter_name("ja"), do: CheckDay.greeter() || "ここを見ている人"
  defp greeter_name("ko"), do: CheckDay.greeter() || "이곳을 돌보는 사람"
  defp greeter_name("en"), do: CheckDay.greeter() || "the person who looks after this place"

  defp to_line("ja", nil), do: "こんにちは。"
  defp to_line("ja", n), do: "#{n} さん"
  defp to_line("ko", nil), do: "안녕하세요."
  defp to_line("ko", n), do: "#{n} 님"
  defp to_line("en", nil), do: "Hello,"
  defp to_line("en", n), do: "Hello #{n},"

  # The greeter's own line, as written; nothing at all when there is none.
  defp quoted(_lang, nil), do: ""
  defp quoted(_lang, ""), do: ""
  defp quoted("ja", t), do: "ひとこと: #{t}\n\n"
  defp quoted("ko", t), do: "한마디: #{t}\n\n"
  defp quoted("en", t), do: "A line from #{greeter_name("en")}: #{t}\n\n"

  defp welcome_subject("ja"), do: "[#{domain()}] お迎えします"
  defp welcome_subject("ko"), do: "[#{domain()}] 맞이합니다"
  defp welcome_subject("en"), do: "[#{domain()}] You are welcome here"

  defp welcome_body("ja", name, note, url) do
    """
    #{to_line("ja", name)}

    申し込み、ありがとうございました。#{greeter_name("ja")}です。お迎えします。

    #{quoted("ja", note)}こちらから、14日のあいだ、一回だけ入れます:

        #{url}

    14日をすぎたら、もういちど申し込んでもらいます(特別扱いは、しません)。
    書いてもらったことと、このメールのアドレスは、このメールを送ったあと、こちらから消しました。

    心当たりがなければ、このメールは、そっと捨ててください。
    """
  end

  defp welcome_body("ko", name, note, url) do
    """
    #{to_line("ko", name)}

    신청해 주셔서 고맙습니다. #{greeter_name("ko")}입니다. 맞이합니다.

    #{quoted("ko", note)}여기에서 14일 동안, 한 번만 들어올 수 있습니다:

        #{url}

    14일이 지나면 다시 신청해 주세요(특별 대우는 하지 않습니다).
    써 주신 내용과 이 메일 주소는, 이 메일을 보낸 뒤 이쪽에서 지웠습니다.

    짚이는 데가 없다면, 이 메일은 그냥 버려 주세요.
    """
  end

  defp welcome_body("en", name, note, url) do
    """
    #{to_line("en", name)}

    Thank you for writing. This is #{greeter_name("en")}. You are welcome here.

    #{quoted("en", note)}This link lets you in once, for 14 days:

        #{url}

    After 14 days you would write again (no one is made an exception).
    What you wrote and this address were deleted on our side once this mail went out.

    If this isn't yours, you can quietly set this email aside.
    """
  end

  defp decline_subject("ja"), do: "[#{domain()}] 申し込みのお返事"
  defp decline_subject("ko"), do: "[#{domain()}] 신청에 대한 답"
  defp decline_subject("en"), do: "[#{domain()}] An answer to your note"

  defp decline_reason(_lang, nil), do: ""
  defp decline_reason(_lang, ""), do: ""
  defp decline_reason(_lang, t), do: t <> "\n\n"

  defp decline_body("ja", name, reason) do
    """
    #{to_line("ja", name)}

    申し込み、ありがとうございました。#{greeter_name("ja")}です。読ませてもらいました。
    今回は、お迎えしないことにしました。

    #{decline_reason("ja", reason)}ここは、ゆっくり時間をかけて待てる人、静かに過ごせる人を望んでいる場所です。
    合う、合わない、ということで、あなたのことが決まるわけではありません。

    書いてもらったことは、このメールを送ったあと、こちらから消します。

    心当たりがなければ、このメールは、そっと捨ててください。
    """
  end

  defp decline_body("ko", name, reason) do
    """
    #{to_line("ko", name)}

    신청해 주셔서 고맙습니다. #{greeter_name("ko")}입니다. 잘 읽었습니다.
    이번에는 맞이하지 않기로 했습니다.

    #{decline_reason("ko", reason)}이곳은 천천히 기다릴 수 있는 사람, 조용히 지낼 수 있는 사람을 바라는 곳입니다.
    맞고 안 맞고가 당신이라는 사람을 정하는 것은 아닙니다.

    써 주신 내용은, 이 메일을 보낸 뒤 이쪽에서 지웁니다.

    짚이는 데가 없다면, 이 메일은 그냥 버려 주세요.
    """
  end

  defp decline_body("en", name, reason) do
    """
    #{to_line("en", name)}

    Thank you for writing. This is #{greeter_name("en")}; I read your note.
    We are not able to welcome you this time.

    #{decline_reason("en", reason)}This is a place for people who can wait slowly and spend time quietly.
    Fitting or not says nothing about who you are.

    What you wrote will be deleted on our side once this mail has gone out.

    If this isn't yours, you can quietly set this email aside.
    """
  end

  defp domain, do: Application.get_env(:sukhi_fedi, :domain, "localhost:4000")
end
