# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Addons.Deco.Federation do
  @moduledoc """
  板が、外の網とやりとりするところ ── よその板を覗く(ベランダ)、
  こちらの板を追ってきた相手を控える、新しく立った話をその相手に配る、
  外から届いた一件を板に結ぶ。

  ここが線の向こうと話す唯一の面。`Deco.Boards` と `Deco.Posts` は
  自分の家のことだけ見ていればよくて、`audience` や `Announce` の形は
  ここに閉じている。

  ベランダは**何も残さない** ── `notes` にも `accounts` にも書かない。
  だから通報も削除もこちらではできないし、できないのが正しい。そこに
  出ているのはよそのおうちの話で、natadeco が載せているものではない。
  """

  import Ecto.Query

  alias SukhiFedi.{Outbox, Repo}
  alias SukhiFedi.Addons.Deco.{Boards, Posts}
  alias SukhiFedi.Federation.CollectionFetcher
  alias SukhiFedi.Schema.{Account, Deco, DecoFollower, DecoNote, Note}

  # ── ベランダ（外の板を見に行く） ─────────────────────────────

  @doc """
  よその板を覗く。追う前に、どんな場所か見るための口。

  引くだけで、**何も残さない** ── `notes` にも `accounts` にも書かない。
  だから通報も削除もこちらではできないし、できないのが正しい。ここに
  出ているのはよそのおうちの話で、natadeco が載せているものではない。
  それが手すり。

  相手の Group actor(`{slug}@host` の形か、actor URI そのもの)を引いて、
  その outbox を読む。Lemmy / PieFed / NodeBB はどれも
  `Announce(Create(Page|Note))` を本文ごと並べているので、一度引けば
  開き手が丸ごと手に入る。

  **開き手しか取れない相手がいる。** Lemmy 0.19 の板の outbox には
  コメントが一件も入っていない(数えた)。会話の中まで読むには相手が
  `context`(FEP-7888)を出している必要があり、それは PieFed と NodeBB
  だけ。取れないものは取れないまま出す ── 「全部見えている」ふりを
  しない。
  """
  @spec peek(String.t()) :: {:ok, map()} | {:error, term()}
  def peek(handle_or_uri) when is_binary(handle_or_uri) do
    with {:ok, actor} <- fetch_remote_actor(handle_or_uri),
         outbox when is_binary(outbox) <- actor["outbox"],
         {:ok, items, meta} <-
           CollectionFetcher.fetch(outbox, sign_as: SukhiFedi.Accounts.signing_identity()) do
      {:ok,
       %{
         actor: remote_actor_view(actor),
         posts: items |> Enum.map(&remote_post_view/1) |> Enum.reject(&is_nil/1),
         truncated: meta.truncated
       }}
    else
      nil -> {:error, :no_outbox}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  end

  defp fetch_remote_actor("http" <> _ = uri), do: SukhiFedi.Federation.ActorFetcher.fetch(uri)

  defp fetch_remote_actor(handle) do
    case SukhiFedi.Federation.WebFinger.resolve_self(handle) do
      {:ok, uri} when is_binary(uri) -> SukhiFedi.Federation.ActorFetcher.fetch(uri)
      _ -> {:error, :not_found}
    end
  end

  defp remote_actor_view(a) do
    %{
      id: a["id"],
      name: a["name"] || a["preferredUsername"],
      handle: a["preferredUsername"],
      summary: a["summary"],
      url: a["url"] || a["id"],
      icon: get_in(a, ["icon", "url"]),
      type: a["type"]
    }
  end

  # `Announce(Create(Page|Note))` も、素の `Create` も、剥いた本体も来る。
  # 本文の在るものだけを拾って、無いものは黙って落とす。
  defp remote_post_view(%{"object" => inner}) when is_map(inner), do: remote_post_view(inner)

  defp remote_post_view(%{"type" => t} = o) when t in ["Page", "Note", "Article", "Question"] do
    %{
      id: o["id"],
      url: o["url"] || o["id"],
      title: o["name"],
      content_html: o["content"],
      author: o["attributedTo"],
      published: o["published"]
    }
  end

  defp remote_post_view(_), do: nil

  # ── 板を追う人（外から） ─────────────────────────────────────

  @doc """
  板が、新しく立った話を追っている相手に配る（FEP-1b12 の `Announce`）。

  **開き手だけ。返信は流さない。** 板を追うと会話の一言ずつが流れて
  くる形にはしない ── 追った人の面に流れるのは「ここで新しい話が
  立った」だけでいい。Lemmy の板の outbox も、数えると開き手しか
  入っていない。

  形は `Announce(<note の URI>)`。FEP-1b12 は `Announce(Create(…))` を
  本筋と書いているが、Mastodon の Announce は object が**オブジェクト
  である前提**で組まれていて、中身がアクティビティだと弾かれる
  (`status_from_object` が nil になる)。掲示板を持つ実装は URI を
  引きに来て、そこで `audience` を見つけられる ── 一つの形で両方に
  届くほうを採った。

  `local_only` の投稿は配らない。表札の無い板は追われようがない。
  """
  @spec announce_new_post(integer(), integer()) :: :ok
  def announce_new_post(deco_id, note_id) when is_integer(deco_id) and is_integer(note_id) do
    with %Note{} = note <- Repo.get(Note, note_id),
         true <- is_nil(note.in_reply_to_ap_id),
         %DecoNote{local_only: false} <- Repo.get_by(DecoNote, note_id: note_id),
         {slug, true} <-
           Repo.one(from(d in Deco, where: d.id == ^deco_id, select: {d.slug, d.has_actor})),
         [_ | _] = inboxes <- follower_inboxes(deco_id),
         %Account{username: username} <- Repo.get(Account, note.account_id) do
      actor = SukhiFedi.AP.GroupJson.actor_uri(slug)
      object = SukhiFedi.Notes.Ids.note_ap_id(note_id) || local_note_uri(username, note_id)

      Outbox.enqueue("sns.outbox.announce.created", "deco", deco_id, %{
        deco_actor: actor,
        object: object,
        activity_id: "#{actor}/announces/#{note_id}",
        inboxes: inboxes
      })
    end

    :ok
  rescue
    _ -> :ok
  end

  defp local_note_uri(username, note_id),
    do: "https://#{SukhiFedi.Config.domain!()}/users/#{username}/notes/#{note_id}"

  @doc """
  板への `Follow` を控える。`manuallyApprovesFollowers` は false と
  名乗っているので、受けた時点で通っている ── 待たせる状態は持たない。

  板の actor URI(`{slug}-deco`)で受け取る。表札を出していない板は
  そもそも引けないので、ここには来ない。
  """
  @spec record_follow(String.t(), String.t(), String.t() | nil) :: :ok | {:error, :not_found}
  def record_follow(deco_actor_uri, follower_uri, inbox_url) do
    case deco_id_from_audience(deco_actor_uri) do
      nil ->
        {:error, :not_found}

      deco_id ->
        %DecoFollower{}
        |> DecoFollower.changeset(%{
          "deco_id" => deco_id,
          "follower_uri" => follower_uri,
          "inbox_url" => inbox_url
        })
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:deco_id, :follower_uri])

        :ok
    end
  end

  @doc "板を追うのをやめた人を落とす（`Undo(Follow)`）。"
  @spec drop_follow(String.t(), String.t()) :: :ok
  def drop_follow(deco_actor_uri, follower_uri) do
    case deco_id_from_audience(deco_actor_uri) do
      nil ->
        :ok

      deco_id ->
        from(f in DecoFollower,
          where: f.deco_id == ^deco_id and f.follower_uri == ^follower_uri
        )
        |> Repo.delete_all()

        :ok
    end
  end

  @doc "その板を追っている相手の inbox。Announce の配り先。"
  @spec follower_inboxes(integer()) :: [String.t()]
  def follower_inboxes(deco_id) when is_integer(deco_id) do
    from(f in DecoFollower,
      where: f.deco_id == ^deco_id and not is_nil(f.inbox_url),
      select: f.inbox_url,
      distinct: true
    )
    |> Repo.all()
  end

  @doc "板を追っている相手の actor URI（followers コレクション用）。"
  @spec follower_uris(String.t()) :: {:ok, [String.t()]} | {:error, :not_found}
  def follower_uris(slug) when is_binary(slug) do
    with {:ok, %Deco{id: id}} <- Boards.get_actor_record(slug) do
      {:ok,
       from(f in DecoFollower, where: f.deco_id == ^id, select: f.follower_uri, order_by: f.id)
       |> Repo.all()}
    end
  end

  @doc """
  この一件が、線の上で名乗るぶん ── どの板のものか(`audience`)と、
  長い文章として出すか(`as_article`)。

  引かれる側(`Web.NoteController`)が使う。配るほうは outbox の payload
  に載って行くが、GET は note 行しか手元に無いので、ここで訊く。
  板に属さない note は両方 nil/false。
  """
  @spec wire_info(integer()) :: %{audience: String.t() | nil, as_article: boolean()}
  def wire_info(note_id) when is_integer(note_id) do
    case Repo.one(
           from(dn in DecoNote,
             join: d in Deco,
             on: d.id == dn.deco_id,
             where: dn.note_id == ^note_id,
             select: {d.slug, d.has_actor, dn.as_article}
           )
         ) do
      {slug, true, article?} ->
        %{audience: SukhiFedi.AP.GroupJson.actor_uri(slug), as_article: !!article?}

      {_slug, _no_actor, article?} ->
        %{audience: nil, as_article: !!article?}

      nil ->
        %{audience: nil, as_article: false}
    end
  end

  @doc """
  外から届いた一件を、板に結ぶ。

  結んでおかないと、板の一覧にも流れにも出てこない ── どちらも
  `deco_notes` を join するので。読むたびに親を遡って板を探すことも
  できるが、それは頁を開くたびに払う値段になる。書き込みの一度で済む。

  どの板かは二段で決める:

    1. `audience`(FEP-1b12) ── 掲示板を持つ実装は自分で名乗ってくれる
    2. 名乗らない相手(Mastodon など)は、返信先を遡って探す

  結べなかったものは、そのまま置く。板の外の会話として普通に流れる。
  """
  @spec bind_inbound(integer(), map()) :: :ok
  def bind_inbound(note_id, raw) when is_integer(note_id) and is_map(raw) do
    with %Note{} = note <- Repo.get(Note, note_id),
         deco_id when is_integer(deco_id) <- inbound_deco_id(note, raw) do
      %DecoNote{}
      |> DecoNote.changeset(%{"deco_id" => deco_id, "note_id" => note_id})
      |> Repo.insert(on_conflict: :nothing, conflict_target: :note_id)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp inbound_deco_id(%Note{} = note, raw) do
    case deco_id_from_audience(raw["audience"]) do
      nil -> Posts.deco_id_for_thread(note)
      id -> id
    end
  end

  # `{slug}-deco` の actor URI から板を引く。他所の板の audience は
  # ここで外れる（自分の domain の形にしか合わないので）。
  # actor URI から板を引く。`audience` と Follow の宛先が同じ形なので
  # 一本で足りる。
  defp deco_id_from_audience(uri) when is_binary(uri) do
    prefix = "https://#{SukhiFedi.Config.domain!()}/users/"

    with true <- String.starts_with?(uri, prefix),
         name <- String.trim_leading(uri, prefix),
         true <- String.ends_with?(name, "-deco"),
         slug <- String.trim_trailing(name, "-deco"),
         %Deco{id: id} <- Repo.get_by(Deco, slug: slug) do
      id
    else
      _ -> nil
    end
  end

  defp deco_id_from_audience(_), do: nil
end
