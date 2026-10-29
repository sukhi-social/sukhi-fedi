# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.AccountDeletionTest do
  @moduledoc """
  Closing an account: a day's grace you can cancel, a mail at both ends,
  every note and credential gone, the handle retired for good.
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import Ecto.Query
  import Plug.Conn
  import Plug.Test

  alias SukhiFedi.{AccountDeletion, Accounts, LocalAccounts, Mailer}
  alias SukhiFedi.Schema.{Account, Note, OutboxEvent, Session}

  setup do
    Mailer.Capture.clear()

    account =
      %Account{
        username: "leaver",
        display_name: "Leaver",
        summary: "<p>bye</p>",
        email: "leaver@example.com",
        email_verified_at: ~U[2026-01-01 00:00:00Z]
      }
      |> Repo.insert!()

    %{account: account}
  end

  defp note!(account, visibility) do
    Repo.insert!(%Note{account_id: account.id, content: "hi", visibility: visibility})
  end

  defp proof_for(email) do
    :ok = SukhiFedi.Auth.EmailAuth.request_signup_code(email)
    %{body: body} = Mailer.Capture.last_to(email)
    [_, code] = Regex.run(~r/\n\s+(\d{6})\n/, body)
    {:ok, proof} = SukhiFedi.Auth.EmailAuth.confirm_signup_code(email, code)
    proof
  end

  defp run_to_the_end(d) do
    case AccountDeletion.finish_step(d) do
      :more -> run_to_the_end(d)
      other -> other
    end
  end

  test "request books one day from now and mails the verified address", %{account: a} do
    now = ~U[2026-10-25 12:00:00Z]
    assert {:ok, d} = AccountDeletion.request(a, now)
    assert d.scheduled_for == ~U[2026-10-26 12:00:00Z]
    assert %{subject: subject, body: body} = Mailer.Capture.last_to("leaver@example.com")
    assert subject =~ "受けつけました"
    assert body =~ "@leaver"
  end

  test "asking again keeps the first booking and sends no second mail", %{account: a} do
    {:ok, d1} = AccountDeletion.request(a, ~U[2026-10-25 12:00:00Z])
    {:ok, d2} = AccountDeletion.request(a, ~U[2026-10-25 18:00:00Z])
    assert d1.id == d2.id
    assert length(Mailer.Capture.all()) == 1
  end

  test "an unverified address gets no mail but the closing is still booked", %{account: a} do
    a = a |> Ecto.Changeset.change(email_verified_at: nil) |> Repo.update!()
    assert {:ok, _} = AccountDeletion.request(a)
    assert Mailer.Capture.all() == []
  end

  test "cancel before the day is up takes it back", %{account: a} do
    {:ok, _} = AccountDeletion.request(a)
    assert :ok = AccountDeletion.cancel(a)
    assert AccountDeletion.pending(a) == nil
    assert AccountDeletion.due(~U[2099-01-01 00:00:00Z]) == []
  end

  test "nothing is due before the day is up", %{account: a} do
    {:ok, d} = AccountDeletion.request(a, ~U[2026-10-25 12:00:00Z])
    assert AccountDeletion.due(~U[2026-10-26 11:59:59Z]) == []
    assert [%{id: id}] = AccountDeletion.due(~U[2026-10-26 12:00:00Z])
    assert id == d.id
  end

  test "closing deletes every note, blanks the account, mails, and queues one actor Delete",
       %{account: a} do
    note!(a, "public")
    note!(a, "direct")
    {:ok, d} = AccountDeletion.request(a, ~U[2026-10-25 12:00:00Z])
    {:ok, _} = LocalAccounts.create_session(a) |> then(&{:ok, &1})
    Mailer.Capture.clear()

    assert :done = run_to_the_end(d)

    assert Repo.aggregate(from(n in Note, where: n.account_id == ^a.id), :count) == 0
    assert Repo.aggregate(from(s in Session, where: s.account_id == ^a.id), :count) == 0

    closed = Repo.get!(Account, a.id)
    assert closed.deleted_at
    assert closed.email == nil
    assert closed.summary == nil
    assert closed.username == "leaver"

    assert %{subject: subject} = Mailer.Capture.last_to("leaver@example.com")
    assert subject =~ "閉じました"

    assert [_one] =
             Repo.all(
               from(e in OutboxEvent,
                 where:
                   e.subject == "sns.outbox.actor.deleted" and e.aggregate_id == ^to_string(a.id)
               )
             )

    assert AccountDeletion.pending(a) == nil
  end

  test "a closed account is gone from lookups, and cannot sign in", %{account: a} do
    {:ok, d} = AccountDeletion.request(a, ~U[2026-10-25 12:00:00Z])
    run_to_the_end(d)

    assert Accounts.by_local_username("leaver") == nil
    assert Accounts.closed_local_username?("leaver")
    refute Accounts.closed_local_username?("someone-else")
    assert {:error, _} = LocalAccounts.authenticate("leaver", "anything")
  end

  test "the handle is retired for good — nobody can take it again", %{account: a} do
    {:ok, d} = AccountDeletion.request(a, ~U[2026-10-25 12:00:00Z])
    run_to_the_end(d)

    {:ok, invite} = SukhiFedi.InviteCodes.issue(a.id)

    assert {:error, {:validation, errors}} =
             LocalAccounts.create(%{
               "username" => "leaver",
               "password" => "correct horse battery staple",
               "invite_code" => invite.code,
               "email_proof" => proof_for("newcomer@example.test")
             })

    assert Map.has_key?(errors, :username)
  end

  test "a closed account cannot ask again", %{account: a} do
    {:ok, d} = AccountDeletion.request(a, ~U[2026-10-25 12:00:00Z])
    run_to_the_end(d)
    assert {:error, :closed} = AccountDeletion.request(Repo.get!(Account, a.id))
  end

  test "once the work has started it can no longer be cancelled", %{account: a} do
    {:ok, d} = AccountDeletion.request(a, ~U[2026-10-25 12:00:00Z])
    :more = AccountDeletion.finish_step(d)
    assert {:error, :started} = AccountDeletion.cancel(a)
  end

  test "the actor URL answers 410 Gone once closed (so a remote can accept the Delete)",
       %{account: a} do
    get = fn ->
      conn(:get, "/users/leaver")
      |> put_req_header("accept", "application/activity+json")
      |> SukhiFedi.Web.Router.call(SukhiFedi.Web.Router.init([]))
    end

    {:ok, d} = AccountDeletion.request(a, ~U[2026-10-25 12:00:00Z])
    assert get.().status == 200
    run_to_the_end(d)
    assert get.().status == 410
  end

  test "the status and cancel endpoints need a session" do
    r =
      conn(:get, "/settings/close/status")
      |> SukhiFedi.Web.Router.call(SukhiFedi.Web.Router.init([]))

    assert r.status == 401

    r =
      conn(:post, "/settings/close/request")
      |> SukhiFedi.Web.Router.call(SukhiFedi.Web.Router.init([]))

    assert r.status == 401
  end
end
