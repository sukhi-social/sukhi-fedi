# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.MediaTranscode do
  @moduledoc """
  Remote media proxy の変換レイヤー。proxy URL の拡張子は今まで CF edge
  cache に乗せるための飾りだったが、`.avif` / `.webp` だけは「この形式で
  欲しい」の合図として読む(MediaProxyController.parse_id)。入力は
  jpeg / png / webp の静止画。

  二段構えで軽くする:

    * **WebP は先(その場)** — encode が速いので、リクエストの中で
      作ってすぐ返す。
    * **AVIF は後(裏)** — 重いので `Worker` が一枚ずつ裏で encode する。
      出来上がるまでの `.avif` リクエストには とりあえず WebP を返す。

  焼き上がりの置き場は二層。`Store`(rustfs / S3)が本体で、一週間は
  置く ─ デプロイのたびに BEAM は再起動するので、メモリだけだと
  そのたび焼き直しになる。`Cache.Ets` の :media_variants は熱い層で、
  :retry の問い直し(60 秒)の間に edge が続けて来るぶんを受けるだけ。

  返り値の三つ目がその含み: `:final` は決着(CF に長く持たせてよい)、
  `:retry` は「今はこれで、また聞いて」(controller が短い cache-control
  を付けるので、CF が問い直したときに出来立ての AVIF を渡せる)。
  ここを長く cache させると、間に合わせの bytes が `.avif` URL に
  永久にピン留めされてしまう。

  これは正しさの層ではないので、迷ったら常に「原本をそのまま」に倒れる:
  対象外の形式・アニメーション・大きすぎる画像・encode 失敗・変換したのに
  縮まなかったとき、ぜんぶ受け取ったままの bytes を返す。URL が `.avif`
  でも中身が webp や jpeg のことがある、ということ ─ ブラウザは
  content-type と中身で見るので、それで困らない。

  AVIF の Q=65 は libheif の換算で aom の cq-level ≒ 22
  (`cq = ((100 - Q) * 63 + 50) / 100`)。既定の Q=50 は cq ≒ 32 で、
  写真に見てわかる劣化が出るので上げてある。effort=2 は箱の 1 コアで
  何秒も encode しないための妥協(2MP のノイズ画像で effort=4 の約
  1/10 の時間、サイズの損は数 %)。
  """

  alias Vix.Vips.Image

  # 変換して意味がある入力だけ。svg はテキストのままが一番軽く、gif は
  # アニメーションごと壊れるので、どちらも触らない。
  @convertible ["image/jpeg", "image/png", "image/webp"]

  @suffix %{avif: ".avif[Q=65,effort=2]", webp: ".webp[Q=80]"}
  @output_ct %{avif: "image/avif", webp: "image/webp"}

  # decode を始める前の画素数の上限(4K)。Mastodon が添付に許すのと同じ
  # 値で、これ以上は decode バッファだけで数十 MB 食うので変換しない。
  @max_pixels 3840 * 2160

  # 熱い層(ETS)の持ち時間。:retry の 60 秒を余裕をもって覆えれば足りる
  # ─ 長い記憶は Store の仕事。
  @hot_ttl 600

  # リクエストの中で同時に走る encode の数。cache miss が束で来たとき
  # (cold cache の 4 枚投稿など)にメモリを守る弁で、席が埋まっていたら
  # 変換せず原本を `:retry` で流すだけ。Worker の AVIF は直列(1 枚ずつ)
  # なので、この弁とは別勘定。
  @max_concurrent 2
  @slots_key {__MODULE__, :slots}

  @typedoc "controller が組む、画像一枚ぶんのキャッシュの鍵。"
  @type variant :: nil | {:avif | :webp, term()}

  @doc """
  `body` を頼まれた形式に encode し直して `{body, content_type, mode}` を
  返す。mode は `:final`(決着、長い cache-control でよい)か `:retry`
  (間に合わせ、短い cache-control で問い直してもらう)。
  変換しない(できない)ときは受け取ったままの bytes を返す。
  """
  @spec maybe(binary(), String.t() | nil, variant()) ::
          {binary(), String.t() | nil, :final | :retry}
  def maybe(body, content_type, nil), do: {body, content_type, :final}

  def maybe(body, content_type, {target, key}) when target in [:avif, :webp] do
    ct = normalize(content_type)

    if ct in @convertible and ct != @output_ct[target] do
      convert(body, content_type, target, key)
    else
      {body, content_type, :final}
    end
  end

  # WebP は速いので、その場で(無ければ作って)決着。
  defp convert(body, ct, :webp, key), do: webp_or_original(body, ct, :final, key)

  defp convert(body, ct, :avif, key) do
    case SukhiFedi.Cache.Ets.get(:media_variants, key) do
      {:ok, {:avif, bytes}} ->
        {bytes, @output_ct[:avif], :final}

      # 裏で試して駄目だった(作れない or 縮まない)ことが分かっている。
      # AVIF はもう待たず、WebP で決着させる。
      {:ok, :reject} ->
        webp_or_original(body, ct, :final, key)

      other ->
        from_store_or_bake(body, ct, key, other)
    end
  end

  defp from_store_or_bake(body, ct, key, cache_state) do
    case __MODULE__.Store.get(key, :avif) do
      {:ok, bytes} ->
        # :retry の窓で edge が続けて来るぶんは熱い層で受ける。
        SukhiFedi.Cache.Ets.put(:media_variants, key, {:avif, bytes}, @hot_ttl)
        {bytes, @output_ct[:avif], :final}

      :miss ->
        avif_not_ready(body, ct, key, cache_state)
    end
  end

  # AVIF がまだ無い(:miss / :pending)。裏に頼んで、今回は WebP でつなぐ。
  defp avif_not_ready(body, ct, key, cache_state) do
    if convertible_image?(body) do
      # :pending(誰かがもう頼んだ)なら重ねて頼まない。
      if cache_state == :miss, do: __MODULE__.Worker.request(key, body)
      webp_or_original(body, ct, :retry, key)
    else
      # アニメーション・4K 超え・壊れた bytes は裏に回しても結果は
      # 同じ。原本で決着。
      {body, ct, :final}
    end
  end

  # WebP を Store から、無ければその場で encode して返す(焼けたら裏で
  # Store へ)。成功と決定的な失敗は flag のまま、席が埋まっていたとき
  # だけは一時的な話なので常に :retry で返す。
  defp webp_or_original(body, ct, flag, key) do
    case __MODULE__.Store.get(key, :webp) do
      {:ok, bytes} ->
        {bytes, @output_ct[:webp], flag}

      :miss ->
        case acquire() do
          {:ok, ref} ->
            try do
              case transcode(body, :webp) do
                {:ok, out} ->
                  __MODULE__.Worker.persist(key, :webp, out)
                  {out, @output_ct[:webp], flag}

                :error ->
                  {body, ct, flag}
              end
            after
              :atomics.sub(ref, 1, 1)
            end

          :busy ->
            {body, ct, :retry}
        end
    end
  end

  @doc false
  # 変換の本体。ガードも smaller チェックも込みで、駄目なら理由を
  # 問わず :error(呼ぶ側はどのみち原本に倒れるだけなので)。
  @spec transcode(binary(), :avif | :webp) :: {:ok, binary()} | :error
  def transcode(body, target) do
    with {:ok, img} <- Image.new_from_buffer(body),
         true <- within_limits?(img),
         {:ok, out} <- Image.write_to_buffer(img, @suffix[target]),
         true <- byte_size(out) < byte_size(body) do
      {:ok, out}
    else
      _ -> :error
    end
  end

  # 「静止画で、大きすぎない」─ encode せずヘッダだけで分かる分。
  defp convertible_image?(body) do
    case Image.new_from_buffer(body) do
      {:ok, img} -> within_limits?(img)
      _ -> false
    end
  end

  defp within_limits?(img) do
    Image.width(img) * Image.height(img) <= @max_pixels and pages(img) == 1
  end

  # アニメーション(animated webp / apng)は 2 ページ以上。new_from_buffer
  # は既定で先頭 1 フレームしか読まないので、そのまま encode すると
  # 静止画に化ける ─ ここで見分けて、触らずに返す。静止画にはこの
  # ヘッダ自体が無いことが多い(それも 1 扱い)。
  defp pages(img) do
    case Image.header_value(img, "n-pages") do
      {:ok, n} when is_integer(n) -> n
      _ -> 1
    end
  end

  defp normalize(ct) when is_binary(ct) do
    ct |> String.split(";") |> hd() |> String.trim() |> String.downcase()
  end

  defp normalize(_), do: nil

  # encode 一回ぶんの席。:atomics なのでプロセスも lock も持たない。
  # 初回の put が競合して ref が二つできても、各自つかんだ ref に
  # 返しにいくので数はずれない。
  defp acquire do
    ref = slots()

    if :atomics.add_get(ref, 1, 1) <= @max_concurrent do
      {:ok, ref}
    else
      :atomics.sub(ref, 1, 1)
      :busy
    end
  end

  defp slots do
    case :persistent_term.get(@slots_key, nil) do
      nil ->
        ref = :atomics.new(1, [])
        :persistent_term.put(@slots_key, ref)
        ref

      ref ->
        ref
    end
  end

  defmodule Store do
    @moduledoc """
    焼いた変換結果の置き場(rustfs / S3、`variants/` prefix)。ここが
    「一週間は置く」の本体 ─ BEAM はデプロイのたびに再起動するので、
    メモリだけだと再起動ごとに全部焼き直しになる。一週間より古いものは
    `prune/0`(Worker が定期で呼ぶ)が消す ─ また見られたら焼き直せば
    いいだけのものなので、置きっぱなしにはしない。

    S3 が無い env では静かに :miss / no-op(変換はその場の encode に
    倒れるだけで、正しさは変わらない)。
    """

    require Logger

    @prefix "variants/"
    @keep_days 7

    @spec get(term(), :avif | :webp) :: {:ok, binary()} | :miss
    def get(key, fmt) do
      with true <- enabled?(),
           {:ok, %{body: body}} <-
             ExAws.S3.get_object(bucket(), object_key(key, fmt)) |> ExAws.request() do
        {:ok, body}
      else
        _ -> :miss
      end
    end

    @spec put(term(), :avif | :webp, binary()) :: :ok
    def put(key, fmt, bytes) do
      if enabled?() do
        case ExAws.S3.put_object(bucket(), object_key(key, fmt), bytes) |> ExAws.request() do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "media_transcode: s3 put failed key=#{object_key(key, fmt)} reason=#{inspect(reason)}"
            )
        end
      end

      :ok
    end

    @doc "一週間より古い変換結果を消す。必要になればまた焼く。"
    @spec prune() :: :ok
    def prune do
      if enabled?(), do: prune_page(nil)
      :ok
    end

    defp prune_page(token) do
      opts = [prefix: @prefix] ++ if token, do: [continuation_token: token], else: []

      case ExAws.S3.list_objects_v2(bucket(), opts) |> ExAws.request() do
        {:ok, %{body: body}} ->
          cutoff = DateTime.add(DateTime.utc_now(), -@keep_days, :day)

          for %{key: key, last_modified: lm} <- Map.get(body, :contents) || [],
              # prefix で絞って聞いているが、消す直前にももう一度確かめる
              # ─ ここで間違えると本物のメディアが消えるので。
              String.starts_with?(key, @prefix),
              older_than?(lm, cutoff) do
            ExAws.S3.delete_object(bucket(), key) |> ExAws.request()
          end

          case body do
            %{is_truncated: "true", next_continuation_token: t} when is_binary(t) and t != "" ->
              prune_page(t)

            _ ->
              :ok
          end

        {:error, reason} ->
          Logger.warning("media_transcode: s3 prune list failed reason=#{inspect(reason)}")
          :ok
      end
    end

    defp older_than?(last_modified, cutoff) when is_binary(last_modified) do
      case DateTime.from_iso8601(last_modified) do
        {:ok, dt, _} -> DateTime.compare(dt, cutoff) == :lt
        _ -> false
      end
    end

    defp older_than?(_, _), do: false

    defp object_key({kind, id, hash}, fmt), do: "#{@prefix}#{kind}-#{id}-#{hash}.#{fmt}"

    defp enabled?, do: Application.get_env(:sukhi_fedi, :s3, [])[:enabled] == true
    defp bucket, do: Application.get_env(:sukhi_fedi, :s3, [])[:bucket] || "media"
  end

  defmodule Worker do
    @moduledoc """
    AVIF の裏 encode と、焼き上がりの持ち運び。GenServer の mailbox が
    そのまま待ち行列で、一枚ずつ順番に encode して `Store`(一週間)と
    `Cache.Ets` の `:media_variants`(熱い層)に置く。直列なのが弁を
    兼ねる(1 コアの箱で AVIF を並べて走らせない)。

    `:reject`(作れない/縮まない)は決定的なので ETS に長めに覚える。
    `:pending` は「もう頼んだ」の印で、途中で落ちても TTL が外れて次の
    リクエストが頼み直す。Store の掃除(一週間より古い変換結果の削除)も
    ここが定期でやる。
    """

    use GenServer

    alias SukhiFedi.Cache.Ets
    alias SukhiFedi.Web.MediaTranscode
    alias SukhiFedi.Web.MediaTranscode.Store

    @table :media_variants
    @pending_ttl 120
    @hot_ttl 600
    @reject_ttl 3600
    @prune_interval_ms :timer.hours(6)

    def start_link(_opts) do
      GenServer.start_link(__MODULE__, [], name: __MODULE__)
    end

    @doc "AVIF encode を頼む。印だけ置いてすぐ返る。"
    def request(key, body) do
      Ets.put(@table, key, :pending, @pending_ttl)
      GenServer.cast(__MODULE__, {:encode, key, body})
    end

    @doc "焼けた bytes の Store 書き込みをリクエストの外に逃がす。"
    def persist(key, fmt, bytes) do
      GenServer.cast(__MODULE__, {:persist, key, fmt, bytes})
    end

    @doc false
    # テスト用: 頼んだ分が全部処理されるのを待つ。
    def drain, do: GenServer.call(__MODULE__, :drain, 30_000)

    @impl true
    def init(_) do
      schedule_prune()
      {:ok, nil}
    end

    @impl true
    def handle_cast({:encode, key, body}, state) do
      # request/2 の印→cast の間に同じ鍵が二度来ることはあり得るが、
      # 二度目はここで出来上がりを見て素通りする。
      case Ets.get(@table, key) do
        {:ok, {:avif, _}} ->
          :ok

        {:ok, :reject} ->
          :ok

        _ ->
          case MediaTranscode.transcode(body, :avif) do
            {:ok, bytes} ->
              Store.put(key, :avif, bytes)
              Ets.put(@table, key, {:avif, bytes}, @hot_ttl)

            :error ->
              Ets.put(@table, key, :reject, @reject_ttl)
          end
      end

      {:noreply, state}
    end

    def handle_cast({:persist, key, fmt, bytes}, state) do
      Store.put(key, fmt, bytes)
      {:noreply, state}
    end

    @impl true
    def handle_info(:prune, state) do
      Store.prune()
      schedule_prune()
      {:noreply, state}
    end

    @impl true
    def handle_call(:drain, _from, state), do: {:reply, :ok, state}

    defp schedule_prune do
      Process.send_after(self(), :prune, @prune_interval_ms)
    end
  end
end
