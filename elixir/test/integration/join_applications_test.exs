# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.JoinApplicationsTest do
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.{JoinApplications, Mailer}
  alias SukhiFedi.Schema.JoinApplication

  defmodule Broken do
    @behaviour SukhiFedi.Mailer
    @impl true
    def deliver(_conf, _to, _subject, _body), do: {:error, :down}
  end

  setup do
    Mailer.Capture.clear()
    previous = Application.get_env(:sukhi_fedi, :join)
    Application.put_env(:sukhi_fedi, :join, check_days: [4], utc_offset_hours: 9, greeter: "くろ")
    on_exit(fn -> Application.put_env(:sukhi_fedi, :join, previous || []) end)

    n = System.unique_integer([:positive])
    %{email: "applicant_#{n}@example.test"}
  end

  defp attrs(email, extra \\ %{}) do
    Map.merge(
      %{
        "email" => email,
        "call_name" => "ゆき",
        "found" => "友だちが話していました。",
        "hope" => "夜に、ゆっくり読みたいです。",
        "lang" => "ja"
      },
      extra
    )
  end

  defp errors_on(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, _opts} -> msg end)
  end

  defp edit_key_from(email) do
    %{body: body} = Mailer.Capture.last_to(email)
    [_, key] = Regex.run(~r{/join/edit/([A-Za-z0-9_-]+)}, body)
    key
  end

  describe "submit/2" do
    test "saves it and mails a receipt that carries only the number", %{email: email} do
      assert {:ok, %{application: app, claim: claim}} = JoinApplications.submit(attrs(email))

      assert app.receipt =~ ~r/^\d{6}$/
      assert app.confirmed_at == nil
      assert app.edit_hash == nil
      assert app.check_on.__struct__ == Date

      # Hashed at rest: the claim itself is not what is stored.
      refute app.claim_hash == claim
      assert byte_size(claim) >= 32

      mail = Mailer.Capture.last_to(email)
      assert mail.subject =~ app.receipt
      assert mail.body =~ app.receipt
      # What was written never leaves in the first mail.
      refute mail.body =~ "ゆき"
      refute mail.body =~ "友だち"
      refute mail.body =~ claim
    end

    test "every question is optional; only the address is needed", %{email: email} do
      assert {:ok, %{application: app}} = JoinApplications.submit(%{"email" => email})
      assert app.call_name == nil and app.found == nil and app.hope == nil

      assert {:error, cs} = JoinApplications.submit(%{"call_name" => "ゆき"})
      assert %{email: [_ | _]} = errors_on(cs)

      assert {:error, cs} = JoinApplications.submit(%{"email" => "not-an-address"})
      assert %{email: [_ | _]} = errors_on(cs)
    end

    test "answers are trimmed, blanks are nothing, and long ones are refused", %{email: email} do
      assert {:ok, %{application: app}} =
               JoinApplications.submit(attrs(email, %{"call_name" => "  ゆき ", "found" => "   "}))

      assert app.call_name == "ゆき"
      assert app.found == nil

      assert {:error, cs} =
               JoinApplications.submit(attrs(email, %{"hope" => String.duplicate("あ", 2001)}))

      assert %{hope: [_ | _]} = errors_on(cs)
    end

    test "the address is normalised and the language is one we know", %{email: email} do
      assert {:ok, %{application: app}} =
               JoinApplications.submit(
                 attrs("  " <> String.upcase(email) <> " ", %{"lang" => "fr"})
               )

      assert app.email == email
      assert app.lang == nil
    end

    test "the keys cannot be written from the request", %{email: email} do
      assert {:ok, %{application: app}} =
               JoinApplications.submit(
                 attrs(email, %{
                   "receipt" => "000000",
                   "edit_hash" => "x",
                   "confirmed_at" => "2026-01-01T00:00:00Z"
                 })
               )

      refute app.receipt == "000000"
      assert app.edit_hash == nil
      assert app.confirmed_at == nil
    end

    test "a receipt mail that does not go out leaves nothing", %{email: email} do
      conf = Application.get_env(:sukhi_fedi, :mailer)
      Application.put_env(:sukhi_fedi, :mailer, Keyword.put(conf, :transport, __MODULE__.Broken))
      on_exit(fn -> Application.put_env(:sukhi_fedi, :mailer, conf) end)

      before = SukhiFedi.AccountRepo.aggregate(JoinApplication, :count)
      assert {:error, :send_failed} = JoinApplications.submit(attrs(email))
      assert SukhiFedi.AccountRepo.aggregate(JoinApplication, :count) == before
    end

    test "the same address is limited to three mails in a quarter hour", %{email: email} do
      for _ <- 1..3, do: assert({:ok, _} = JoinApplications.submit(attrs(email)))
      assert {:error, :rate_limited} = JoinApplications.submit(attrs(email))
    end
  end

  describe "received/1" do
    test "mails the edit link once, and only after yes", %{email: email} do
      {:ok, %{claim: claim, application: app}} = JoinApplications.submit(attrs(email))
      assert length(Mailer.Capture.all()) == 1

      assert {:ok, confirmed} = JoinApplications.received(claim)
      assert %DateTime{} = confirmed.confirmed_at
      assert length(Mailer.Capture.all()) == 2

      mail = Mailer.Capture.last_to(email)
      assert mail.body =~ app.receipt
      key = edit_key_from(email)
      refute confirmed.edit_hash == key

      # Said twice, mailed once.
      assert {:ok, _} = JoinApplications.received(claim)
      assert length(Mailer.Capture.all()) == 2
    end

    test "an edit link that could not be mailed leaves it unconfirmed, to try again", %{
      email: email
    } do
      {:ok, %{claim: claim, application: app}} = JoinApplications.submit(attrs(email))

      conf = Application.get_env(:sukhi_fedi, :mailer)
      Application.put_env(:sukhi_fedi, :mailer, Keyword.put(conf, :transport, __MODULE__.Broken))
      assert {:error, :send_failed} = JoinApplications.received(claim)
      Application.put_env(:sukhi_fedi, :mailer, conf)

      row = SukhiFedi.AccountRepo.get(JoinApplication, app.id)
      assert row.confirmed_at == nil
      assert row.edit_hash == nil

      assert {:ok, _} = JoinApplications.received(claim)
      assert Mailer.Capture.last_to(email).body =~ "/join/edit/"
    end

    test "a claim nobody holds opens nothing" do
      assert {:error, :not_found} = JoinApplications.received("nope")
      assert {:error, :not_found} = JoinApplications.received("")
      assert {:error, :not_found} = JoinApplications.received(nil)
    end
  end

  describe "change_email/2" do
    test "moves the receipt to the corrected address, before any yes", %{email: email} do
      {:ok, %{claim: claim, application: app}} = JoinApplications.submit(attrs("yuki_#{email}"))
      fixed = email

      assert {:ok, moved} = JoinApplications.change_email(claim, fixed)
      assert moved.id == app.id
      assert moved.email == fixed
      assert Mailer.Capture.last_to(fixed).body =~ app.receipt
    end

    test "is closed once someone said yes", %{email: email} do
      {:ok, %{claim: claim}} = JoinApplications.submit(attrs(email))
      {:ok, _} = JoinApplications.received(claim)

      assert {:error, :confirmed} = JoinApplications.change_email(claim, "other_#{email}")
    end

    test "a bad address keeps the old one", %{email: email} do
      {:ok, %{claim: claim}} = JoinApplications.submit(attrs(email))
      assert {:error, %Ecto.Changeset{}} = JoinApplications.change_email(claim, "nope")
      assert {:error, :not_found} = JoinApplications.change_email("nope", email)
    end
  end

  describe "the edit link" do
    test "shows the words and rewrites them; the address stays", %{email: email} do
      {:ok, %{claim: claim}} = JoinApplications.submit(attrs(email))
      {:ok, _} = JoinApplications.received(claim)
      key = edit_key_from(email)

      assert {:ok, app} = JoinApplications.fetch_by_key(key)
      assert app.call_name == "ゆき"

      assert {:ok, edited} =
               JoinApplications.edit(key, %{
                 "call_name" => "ゆきの",
                 "hope" => "",
                 "email" => "other@example.test"
               })

      assert edited.call_name == "ゆきの"
      assert edited.hope == nil
      assert edited.email == email
    end

    test "before yes there is no key, and a wrong one opens nothing", %{email: email} do
      {:ok, %{claim: claim}} = JoinApplications.submit(attrs(email))
      refute edit_key_from_if_any(email)

      assert {:error, :not_found} = JoinApplications.fetch_by_key(claim)
      assert {:error, :not_found} = JoinApplications.fetch_by_key("wrong")
      assert {:error, :not_found} = JoinApplications.edit("wrong", %{"call_name" => "x"})
    end
  end

  describe "purge_unconfirmed/1" do
    test "deletes what nobody confirmed after three hours, keeps the rest", %{email: email} do
      {:ok, %{claim: kept_claim, application: kept}} =
        JoinApplications.submit(attrs("kept_" <> email))

      {:ok, _} = JoinApplications.received(kept_claim)
      {:ok, %{application: stale}} = JoinApplications.submit(attrs("stale_" <> email))
      {:ok, %{application: fresh}} = JoinApplications.submit(attrs("fresh_" <> email))

      long_ago =
        DateTime.add(DateTime.utc_now(), -4 * 3600, :second) |> DateTime.truncate(:second)

      for a <- [kept, stale],
          do: a |> Ecto.Changeset.change(created_at: long_ago) |> SukhiFedi.AccountRepo.update!()

      assert JoinApplications.purge_unconfirmed() == 1
      assert SukhiFedi.AccountRepo.get(JoinApplication, stale.id) == nil
      assert SukhiFedi.AccountRepo.get(JoinApplication, fresh.id)
      assert SukhiFedi.AccountRepo.get(JoinApplication, kept.id)
    end
  end

  describe "info/1" do
    test "names who looks and the day" do
      info = JoinApplications.info(DateTime.new!(~D[2026-11-02], ~T[03:00:00]))
      assert info == %{greeter: "くろ", check_on: ~D[2026-11-05], weekday: 4, days_after: 3}
    end
  end

  defp edit_key_from_if_any(email) do
    case Mailer.Capture.last_to(email) do
      %{body: body} -> Regex.run(~r{/join/edit/}, body)
      _ -> nil
    end
  end

  # ── step 2: the greeter reads, welcomes, declines ───────────────────────

  defp confirmed(email, extra \\ %{}) do
    {:ok, %{application: app, claim: claim}} = JoinApplications.submit(attrs(email, extra))
    {:ok, _} = JoinApplications.received(claim)
    app
  end

  defp entry_key_from(email) do
    %{body: body} = Mailer.Capture.last_to(email)
    [_, key] = Regex.run(~r{/welcome/([A-Za-z0-9_-]+)}, body)
    key
  end

  defp break_mail do
    conf = Application.get_env(:sukhi_fedi, :mailer)
    Application.put_env(:sukhi_fedi, :mailer, Keyword.put(conf, :transport, __MODULE__.Broken))
    on_exit(fn -> Application.put_env(:sukhi_fedi, :mailer, conf) end)
  end

  describe "list_waiting/0 and fetch_waiting/1" do
    test "only the ones who said yes to the receipt are waiting", %{email: email} do
      {:ok, %{application: unconfirmed}} = JoinApplications.submit(attrs(email))
      other = "other_#{System.unique_integer([:positive])}@example.test"
      app = confirmed(other)

      receipts = JoinApplications.list_waiting() |> Enum.map(& &1.receipt)
      assert app.receipt in receipts
      refute unconfirmed.receipt in receipts

      assert {:ok, %{receipt: r}} = JoinApplications.fetch_waiting(app.receipt)
      assert r == app.receipt
      # the number as it is read aloud: grouped
      grouped = String.slice(app.receipt, 0, 3) <> " " <> String.slice(app.receipt, 3, 3)
      assert {:ok, _} = JoinApplications.fetch_waiting(grouped)

      assert {:error, :not_found} = JoinApplications.fetch_waiting(unconfirmed.receipt)
      assert {:error, :not_found} = JoinApplications.fetch_waiting("nope")
    end
  end

  describe "welcome/3" do
    test "mails a 14-day entry link with the line as written, then forgets the words",
         %{email: email} do
      app = confirmed(email)

      assert {:ok, welcomed} = JoinApplications.welcome(app.receipt, "夜の読書の話、すてきでした。", 1)

      mail = Mailer.Capture.last_to(email)
      assert mail.body =~ "ゆき さん"
      assert mail.body =~ "夜の読書の話、すてきでした。"
      assert mail.body =~ "14日"
      # nothing is promised that the no-reply address cannot keep
      refute mail.body =~ "返信できます"

      key = entry_key_from(email)
      assert byte_size(key) >= 32
      assert :ok = JoinApplications.entry_status(key)

      # Hashed at rest, and the words and the address are gone.
      stored = SukhiFedi.AccountRepo.get!(JoinApplication, welcomed.id)
      refute stored.entry_hash == key
      assert stored.welcomed_at
      assert stored.email == nil
      assert stored.call_name == nil and stored.found == nil and stored.hope == nil
      assert stored.edit_hash == nil

      assert {:error, :not_found} = JoinApplications.fetch_waiting(app.receipt)
      refute app.receipt in Enum.map(JoinApplications.list_waiting(), & &1.receipt)
    end

    test "a welcome without a line, or a name, still reads whole", %{email: email} do
      app = confirmed(email, %{"call_name" => ""})
      assert {:ok, _} = JoinApplications.welcome(app.receipt, nil, 1)
      mail = Mailer.Capture.last_to(email)
      refute mail.body =~ "ひとこと"
      assert mail.body =~ "こんにちは。"
    end

    test "a mail that does not go leaves it waiting, with the words", %{email: email} do
      app = confirmed(email)
      break_mail()

      assert {:error, :send_failed} = JoinApplications.welcome(app.receipt, "ようこそ", 1)

      stored = SukhiFedi.AccountRepo.get!(JoinApplication, app.id)
      assert stored.entry_hash == nil and stored.welcomed_at == nil
      assert stored.email == email and stored.hope == "夜に、ゆっくり読みたいです。"
      assert {:ok, _} = JoinApplications.fetch_waiting(app.receipt)
    end

    test "one that never said yes cannot be welcomed", %{email: email} do
      {:ok, %{application: app}} = JoinApplications.submit(attrs(email))
      assert {:error, :not_found} = JoinApplications.welcome(app.receipt, "ようこそ", 1)
    end
  end

  describe "decline/2" do
    test "answers gently, with the reason as written, then deletes it", %{email: email} do
      app = confirmed(email)

      assert :ok = JoinApplications.decline(app.receipt, "今は、受けられる人数がいっぱいです。", 1)

      mail = Mailer.Capture.last_to(email)
      assert mail.body =~ "お迎えしないことにしました"
      assert mail.body =~ "今は、受けられる人数がいっぱいです。"
      refute mail.body =~ "/welcome/"

      assert SukhiFedi.AccountRepo.get(JoinApplication, app.id) == nil
    end

    test "a mail that does not go leaves it where it was", %{email: email} do
      app = confirmed(email)
      break_mail()

      assert {:error, :send_failed} = JoinApplications.decline(app.receipt, nil, 1)
      assert {:ok, _} = JoinApplications.fetch_waiting(app.receipt)
    end
  end

  describe "entry keys" do
    test "work once", %{email: email} do
      app = confirmed(email)
      {:ok, _} = JoinApplications.welcome(app.receipt, nil, 1)
      key = entry_key_from(email)

      assert {:ok, %JoinApplication{joined_at: %DateTime{}}} = JoinApplications.consume_entry(key)
      assert {:error, :used} = JoinApplications.consume_entry(key)
      assert {:error, :used} = JoinApplications.entry_status(key)
    end

    test "stop working after 14 days", %{email: email} do
      app = confirmed(email)
      {:ok, _} = JoinApplications.welcome(app.receipt, nil, 1)
      key = entry_key_from(email)

      just_before = DateTime.add(DateTime.utc_now(), 13 * 24 * 3600, :second)
      later = DateTime.add(DateTime.utc_now(), 15 * 24 * 3600, :second)

      assert :ok = JoinApplications.entry_status(key, just_before)
      assert {:error, :expired} = JoinApplications.entry_status(key, later)
      assert {:error, :expired} = JoinApplications.consume_entry(key, later)
    end

    test "a guessed key opens nothing" do
      assert {:error, :invalid} = JoinApplications.entry_status("nope")
      assert {:error, :invalid} = JoinApplications.consume_entry("nope")
      assert {:error, :invalid} = JoinApplications.entry_status("")
    end
  end

  describe "the trail, and the length of the greeter's line" do
    defp audits(action, receipt) do
      import Ecto.Query

      SukhiFedi.AccountRepo.all(
        from a in SukhiFedi.Schema.AdminAudit,
          where: a.action == ^action
      )
      |> Enum.filter(&(&1.metadata["receipt"] == receipt or &1.metadata[:receipt] == receipt))
    end

    test "welcoming writes who and which receipt — nothing they wrote", %{email: email} do
      app = confirmed(email)
      {:ok, _} = JoinApplications.welcome(app.receipt, "ようこそ", 42)

      assert [row] = audits("join_welcomed", app.receipt)
      assert row.admin_account_id == 42
      raw = inspect(row)
      refute raw =~ email
      refute raw =~ "ゆき"
      refute raw =~ "ゆっくり"
    end

    test "declining writes it too, and the application is gone", %{email: email} do
      app = confirmed(email)
      :ok = JoinApplications.decline(app.receipt, nil, 42)

      assert [row] = audits("join_declined", app.receipt)
      assert row.admin_account_id == 42
      refute inspect(row) =~ email
    end

    test "a mail that did not go leaves no trail", %{email: email} do
      app = confirmed(email)
      break_mail()
      {:error, :send_failed} = JoinApplications.welcome(app.receipt, nil, 42)
      {:error, :send_failed} = JoinApplications.decline(app.receipt, nil, 42)

      assert audits("join_welcomed", app.receipt) == []
      assert audits("join_declined", app.receipt) == []
    end

    test "a line over 500 characters is refused before any mail, at 500 it goes", %{email: email} do
      app = confirmed(email)
      Mailer.Capture.clear()

      assert {:error, :too_long} =
               JoinApplications.welcome(app.receipt, String.duplicate("あ", 501), 1)

      assert {:error, :too_long} =
               JoinApplications.decline(app.receipt, String.duplicate("あ", 501), 1)

      assert Mailer.Capture.last_to(email) == nil
      assert {:ok, _} = JoinApplications.fetch_waiting(app.receipt)

      assert {:ok, _} = JoinApplications.welcome(app.receipt, String.duplicate("あ", 500), 1)
    end

    test "a blank line is no line", %{email: email} do
      app = confirmed(email)
      assert {:ok, _} = JoinApplications.welcome(app.receipt, "   \n ", 1)
      refute Mailer.Capture.last_to(email).body =~ "ひとこと"
    end
  end
end
