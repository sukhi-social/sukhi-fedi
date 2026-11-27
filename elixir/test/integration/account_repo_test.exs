# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.AccountRepoTest do
  @moduledoc """
  `SukhiFedi.AccountRepo`: the accounts' PostgreSQL tables take the same
  schemas the Datalevin store did, and keep the guarantees the database gives
  (unique local names, account and audit rows that stay) — among them that an
  account change and its outbox event are one transaction.

      make test-pgrust ARGS="test/integration/account_repo_test.exs"
  """

  use SukhiFedi.IntegrationCase, async: false

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  @moduletag :integration

  alias SukhiFedi.AccountRepo
  alias SukhiFedi.Schema.{Account, AccountDeletion, AdminAudit, OutboxEvent}
  alias SukhiFedi.Schema.{EmailCode, InviteCode, InviteCodeUse, JoinApplication, Session}
  alias SukhiFedi.Schema.{OauthAccessToken, OauthApp, OauthAuthorizationCode}
  alias SukhiFedi.Schema.{WebauthnChallenge, WebauthnCredential}

  # Every schema kept here, each after the rows it points at.
  @schemas [
    Account,
    OauthApp,
    InviteCode,
    InviteCodeUse,
    JoinApplication,
    Session,
    OauthAccessToken,
    OauthAuthorizationCode,
    WebauthnCredential,
    WebauthnChallenge,
    EmailCode,
    AccountDeletion,
    AdminAudit,
    OutboxEvent
  ]

  # A field that points at another row takes the id of the one written before.
  @points_at %{
    account_id: Account,
    suspended_by_id: Account,
    issued_by_id: Account,
    on_behalf_of_id: Account,
    owner_account_id: Account,
    app_id: OauthApp,
    invite_code_id: InviteCode
  }

  # Each test starts here: a row left behind by an earlier test, in a table the
  # wipe forgot, fails the next one.
  defp assert_all_empty! do
    for schema <- [Account, OutboxEvent, AdminAudit, AccountDeletion] do
      assert AccountRepo.aggregate(schema, :count) == 0, "#{inspect(schema)} was not emptied"
    end
  end

  defp enqueue!(subject, attrs \\ %{}) do
    base = %{subject: subject, aggregate_type: "note", aggregate_id: "1", payload: %{"note_id" => 1}}

    %OutboxEvent{}
    |> OutboxEvent.changeset(Map.merge(base, attrs))
    |> AccountRepo.insert!()
  end

  defp deletion_request(account_id) do
    %AccountDeletion{}
    |> change(
      account_id: account_id,
      requested_at: ~U[2026-01-01 00:00:00Z],
      scheduled_for: ~U[2026-01-31 00:00:00Z]
    )
    |> unique_constraint(:account_id, name: :account_deletions_live_index)
  end

  defp local(attrs) do
    base = %{username: "alice"}
    Map.merge(base, Map.new(attrs))
  end

  defp insert!(attrs) do
    %Account{} |> change(local(attrs)) |> AccountRepo.insert!()
  end

  # A value that is not the column's default, so a field that was dropped on
  # the way in or out shows.
  defp sample(field, :string), do: String.slice("#{field}", 0, 8)
  defp sample(_, type) when type in [:id, :integer], do: 7
  defp sample(_, :boolean), do: true
  defp sample(_, :binary), do: <<0, 255, 1>>
  defp sample(_, :date), do: ~D[2026-02-03]
  defp sample(_, :utc_datetime), do: ~U[2026-02-03 04:05:06Z]
  defp sample(_, :utc_datetime_usec), do: ~U[2026-02-03 04:05:06.123456Z]
  defp sample(field, :map), do: %{"field" => "#{field}"}
  defp sample(field, {:array, type}), do: [sample(field, type)]

  test "the tables start empty for each test" do
    assert_all_empty!()
  end

  test "every field of every schema is written and read back" do
    Enum.reduce(@schemas, %{}, fn schema, ids ->
      values =
        for field <- schema.__schema__(:fields), field != :id, into: %{} do
          case @points_at[field] do
            nil -> {field, sample(field, schema.__schema__(:type, field))}
            # The first account suspends nobody: there is no row to name yet.
            target -> {field, ids[target]}
          end
        end

      %{id: id} = AccountRepo.insert!(struct!(schema, values))
      read = AccountRepo.get!(schema, id)

      assert Map.take(read, Map.keys(values)) == values, inspect(schema)
      Map.put(ids, schema, id)
    end)
  end

  test "text the app lets through is not cut short by a column" do
    # 40 graphemes, 200 code points: within the form's limit for a call name.
    family = String.duplicate("👨‍👩‍👧", 40)
    long = String.duplicate("a", 1000)
    account = insert!([])

    for {struct, field, value} <- [
          {%JoinApplication{receipt: "r", claim_hash: "c"}, :call_name, family},
          {%InviteCode{code: "i"}, :note, long},
          {%WebauthnCredential{account_id: account.id, cose_key: <<1>>, credential_id: "n"},
           :nickname, family},
          {%WebauthnCredential{account_id: account.id, cose_key: <<1>>}, :credential_id, long}
        ] do
      %schema{id: id} = AccountRepo.insert!(Map.put(struct, field, value))
      assert Map.fetch!(AccountRepo.get!(schema, id), field) == value, "#{inspect(schema)}.#{field}"
    end
  end

  test "a welcomed application can be emptied of what the person wrote" do
    app =
      AccountRepo.insert!(%JoinApplication{
        receipt: "r",
        email: "someone@example.test",
        call_name: "a",
        found: "b",
        hope: "c",
        claim_hash: "claim",
        edit_hash: "edit"
      })

    app |> JoinApplication.scrub_changeset() |> AccountRepo.update!()

    assert %{email: nil, call_name: nil, found: nil, hope: nil, edit_hash: nil} =
             AccountRepo.get!(JoinApplication, app.id)
  end

  test "every kind of column reads back as it was written" do
    attrs = %{
      username: "alice",
      display_name: "Alice",
      email: "alice@example.test",
      password_hash: "hash",
      emojis: [%{"shortcode" => "star", "url" => "https://example.test/star.png"}],
      fields: [%{"name" => "site", "value" => "https://example.test"}],
      roles: [%{"name" => "helper", "color" => "#aabbcc"}],
      avatar_decorations: [%{"url" => "https://example.test/d.png", "angle" => 0}],
      aliases: ["https://other.test/users/alice"],
      public_key_jwk: %{"kty" => "RSA", "n" => "abc", "e" => "AQAB"},
      private_key_jwk: %{"kty" => "RSA", "d" => "secret"},
      ed25519_private_key_jwk: %{"kty" => "OKP", "d" => "secret"},
      totp_secret: <<1, 2, 3, 0, 255>>,
      translate_deepl_key: <<9, 8, 7>>,
      birthday: ~D[2000-02-29],
      suspended_at: ~U[2026-01-02 03:04:05Z],
      notification_hold_minutes: 15,
      is_admin: true
    }

    a = insert!(attrs)
    assert is_integer(a.id)
    assert %DateTime{} = a.created_at

    b = AccountRepo.get!(Account, a.id)

    for {k, v} <- attrs do
      assert Map.fetch!(b, k) == v, "#{k} did not read back"
    end

    # the defaults the column carries
    assert b.locked == false
    assert b.translate_auto == false
    assert b.backfill_mirrored == 0
  end

  test "a local username is unique, a remote one may repeat a local one" do
    insert!(username: "alice")

    dup =
      %Account{}
      |> change(username: "alice")
      |> unique_constraint(:username, name: :accounts_local_username_index)

    assert {:error, cs} = AccountRepo.insert(dup)
    assert {"has already been taken", _} = cs.errors[:username]

    assert %Account{} =
             insert!(username: "alice", domain: "remote.test", actor_uri: "https://remote.test/u/alice")
  end

  test "a verified local email is unique whatever its case" do
    insert!(username: "alice", email: "A@Example.test", email_verified_at: ~U[2026-01-01 00:00:00Z])

    dup =
      %Account{}
      |> change(username: "bob", email: "a@example.test", email_verified_at: ~U[2026-01-01 00:00:00Z])
      |> unique_constraint(:email, name: :accounts_local_email_index)

    assert {:error, _} = AccountRepo.insert(dup)
  end

  test "an account row is never deleted" do
    a = insert!(username: "alice")

    assert_raise Postgrex.Error, ~r/accounts keeps its rows/, fn -> AccountRepo.delete!(a) end
    assert AccountRepo.get(Account, a.id)
  end

  test "an outbox row is born pending, and what it carries reads back" do
    assert_all_empty!()

    e =
      enqueue!("sns.outbox.note.created", %{
        payload: %{"note_id" => 1, "tags" => ["a", "b"]},
        headers: %{"trace" => "x"}
      })

    got = AccountRepo.get!(OutboxEvent, e.id)
    assert got.status == "pending"
    assert got.attempts == 0
    assert got.published_at == nil
    assert got.payload == %{"note_id" => 1, "tags" => ["a", "b"]}
    assert got.headers == %{"trace" => "x"}
    assert %DateTime{} = got.inserted_at
  end

  test "the relay's poll takes pending rows, oldest first, a batch at a time, and its flip leaves the rest" do
    assert_all_empty!()

    [first, second, third, fourth, fifth] =
      for n <- 1..5, do: enqueue!("sns.outbox.like.created", %{aggregate_id: "#{n}"}).id

    # `second` was published already
    from(e in OutboxEvent, where: e.id == ^second)
    |> AccountRepo.update_all(set: [status: "published", published_at: DateTime.utc_now()])

    pending =
      from(e in OutboxEvent, where: e.status == "pending", order_by: [asc: e.id], limit: 3)
      |> AccountRepo.all()

    assert Enum.map(pending, & &1.id) == [first, third, fourth]

    {3, _} =
      from(e in OutboxEvent, where: e.id in ^Enum.map(pending, & &1.id))
      |> AccountRepo.update_all(set: [status: "published", published_at: DateTime.utc_now()])

    assert AccountRepo.all(from(e in OutboxEvent, where: e.status == "pending", select: e.id)) == [fifth]
  end

  test "an account change and its outbox event commit together, or not at all" do
    assert_all_empty!()

    event_for = fn multi ->
      SukhiFedi.Outbox.enqueue_multi(
        multi,
        :event,
        "sns.outbox.actor.updated",
        "account",
        & &1.account.id,
        fn %{account: a} -> %{account_id: a.id} end
      )
    end

    # a step after the event fails: the account and the event both go
    failed =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:account, change(%Account{}, username: "alice"))
      |> event_for.()
      |> Ecto.Multi.run(:later, fn _repo, _changes -> {:error, :nope} end)
      |> AccountRepo.transaction()

    assert {:error, :later, :nope, _} = failed
    assert_all_empty!()

    {:ok, %{account: a, event: e}} =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:account, change(%Account{}, username: "alice"))
      |> event_for.()
      |> AccountRepo.transaction()

    assert e.aggregate_id == to_string(a.id)
    assert AccountRepo.get!(OutboxEvent, e.id).payload == %{"account_id" => a.id}
  end

  test "the audit trail takes a row whose account is gone or never was here" do
    assert_all_empty!()

    row =
      AdminAudit.changeset(%{
        action: "suspend",
        admin_account_id: 1,
        target_account_id: 99_999,
        reason: "spam",
        metadata: %{"severity" => "high"}
      })
      |> AccountRepo.insert!()

    got = AccountRepo.get!(AdminAudit, row.id)
    assert {got.action, got.reason, got.metadata} == {"suspend", "spam", %{"severity" => "high"}}
    assert %DateTime{} = got.created_at
  end

  test "one live deletion request per account; a cancelled one makes room for the next" do
    assert_all_empty!()
    a = insert!(username: "alice")

    first = AccountRepo.insert!(deletion_request(a.id))

    assert {:error, cs} = AccountRepo.insert(deletion_request(a.id))
    assert {"has already been taken", _} = cs.errors[:account_id]

    first |> change(cancelled_at: ~U[2026-01-02 00:00:00Z]) |> AccountRepo.update!()
    assert %AccountDeletion{} = AccountRepo.insert!(deletion_request(a.id))
  end

  test "an audit row is neither rewritten nor deleted" do
    row =
      %AdminAudit{}
      |> change(action: "suspend", reason: "spam")
      |> AccountRepo.insert!()

    assert_raise Postgrex.Error, ~r/admin_audits keeps its rows/, fn ->
      row |> change(reason: "other") |> AccountRepo.update!()
    end

    assert_raise Postgrex.Error, ~r/admin_audits keeps its rows/, fn -> AccountRepo.delete!(row) end
    assert AccountRepo.get!(AdminAudit, row.id).reason == "spam"
  end
end
