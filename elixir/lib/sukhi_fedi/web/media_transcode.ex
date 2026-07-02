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
    * **AVIF は後(裏)** — 重いので `Worker` が一枚ずつ裏で encode して
      `Cache.Ets` に置く。出来上がるまでの `.avif` リクエストには
      とりあえず WebP を返す。

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

  # WebP は速いので、その場で作って決着。
  defp convert(body, ct, :webp, _key), do: webp_now(body, ct, :final)

  defp convert(body, ct, :avif, key) do
    case SukhiFedi.Cache.Ets.get(:media_variants, key) do
      {:ok, {:avif, bytes}} ->
        {bytes, @output_ct[:avif], :final}

      # 裏で試して駄目だった(作れない or 縮まない)ことが分かっている。
      # AVIF はもう待たず、WebP で決着させる。
      {:ok, :reject} ->
        webp_now(body, ct, :final)

      other ->
        avif_not_ready(body, ct, key, other)
    end
  end

  # AVIF がまだ無い(:miss / :pending)。裏に頼んで、今回は WebP でつなぐ。
  defp avif_not_ready(body, ct, key, cache_state) do
    if convertible_image?(body) do
      # :pending(誰かがもう頼んだ)なら重ねて頼まない。
      if cache_state == :miss, do: __MODULE__.Worker.request(key, body)
      webp_now(body, ct, :retry)
    else
      # アニメーション・4K 超え・壊れた bytes は裏に回しても結果は
      # 同じ。原本で決着。
      {body, ct, :final}
    end
  end

  # その場の WebP encode。成功と決定的な失敗は flag のまま、席が
  # 埋まっていたときだけは一時的な話なので常に :retry で返す。
  defp webp_now(body, ct, flag) do
    case acquire() do
      {:ok, ref} ->
        try do
          case transcode(body, :webp) do
            {:ok, out} -> {out, @output_ct[:webp], flag}
            :error -> {body, ct, flag}
          end
        after
          :atomics.sub(ref, 1, 1)
        end

      :busy ->
        {body, ct, :retry}
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

  defmodule Worker do
    @moduledoc """
    AVIF の裏 encode。GenServer の mailbox がそのまま待ち行列で、
    一枚ずつ順番に encode して `Cache.Ets` の `:media_variants` に置く。
    直列なのが弁を兼ねる(1 コアの箱で AVIF を並べて走らせない)。

    結果の寿命は短くていい ─ `:retry` の cache-control(60 秒)で CF が
    問い直しに来るまで持てば足りるので、AVIF は 10 分。`:reject`
    (作れない/縮まない)は決定的なので長め。`:pending` は「もう頼んだ」
    の印で、途中で落ちても TTL が外れて次のリクエストが頼み直す。
    """

    use GenServer

    alias SukhiFedi.Cache.Ets
    alias SukhiFedi.Web.MediaTranscode

    @table :media_variants
    @pending_ttl 120
    @avif_ttl 600
    @reject_ttl 3600

    def start_link(_opts) do
      GenServer.start_link(__MODULE__, [], name: __MODULE__)
    end

    @doc "AVIF encode を頼む。印だけ置いてすぐ返る。"
    def request(key, body) do
      Ets.put(@table, key, :pending, @pending_ttl)
      GenServer.cast(__MODULE__, {:encode, key, body})
    end

    @doc false
    # テスト用: 頼んだ分が全部処理されるのを待つ。
    def drain, do: GenServer.call(__MODULE__, :drain, 30_000)

    @impl true
    def init(_), do: {:ok, nil}

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
            {:ok, bytes} -> Ets.put(@table, key, {:avif, bytes}, @avif_ttl)
            :error -> Ets.put(@table, key, :reject, @reject_ttl)
          end
      end

      {:noreply, state}
    end

    @impl true
    def handle_call(:drain, _from, state), do: {:reply, :ok, state}
  end
end
