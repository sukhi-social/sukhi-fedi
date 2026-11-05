# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Translate.Key do
  @moduledoc """
  The one place a person's DeepL API key is sealed and opened.

  A key is the person's own, brought to us; what we owe it is that it goes
  nowhere but DeepL. So:

    * it is sealed (AES-GCM through `Plug.Crypto.MessageEncryptor`) with keys
      derived from `secret_key_base`, and the account id is part of what is
      authenticated — a sealed blob copied onto another account does not open;
    * the plaintext exists only inside `seal/2` (on its way in) and `open/2`
      (on its way to the engine request header);
    * `seal/2` also answers the last four characters, the only part a settings
      page may show (`translate_deepl_key_hint`).

  Format check lives here too: a DeepL key is a UUID with an optional `:fx`
  suffix (Free plan). Anything else is `:error`, so a typo or a pasted sentence
  never becomes a stored "key".
  """

  @aad "sukhi.translate.deepl_key.v1"
  @shape ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(:fx)?\z/

  @spec seal(String.t(), integer()) :: {:ok, binary(), String.t()} | :error
  def seal(key, account_id) when is_binary(key) and is_integer(account_id) do
    key = String.trim(key)

    if Regex.match?(@shape, key) do
      {secret, sign} = secrets()
      sealed = Plug.Crypto.MessageEncryptor.encrypt(key, aad(account_id), secret, sign)
      {:ok, sealed, hint(key)}
    else
      :error
    end
  end

  def seal(_key, _account_id), do: :error

  @spec open(binary() | nil, integer()) :: {:ok, String.t()} | :error
  def open(sealed, account_id) when is_binary(sealed) and is_integer(account_id) do
    {secret, sign} = secrets()

    case Plug.Crypto.MessageEncryptor.decrypt(sealed, aad(account_id), secret, sign) do
      {:ok, key} -> {:ok, key}
      :error -> :error
    end
  end

  def open(_sealed, _account_id), do: :error

  # The last four characters of the key proper (the Free plan's `:fx` is a suffix, not part of it).
  defp hint(key), do: key |> String.replace_suffix(":fx", "") |> String.slice(-4, 4)

  defp aad(account_id), do: @aad <> ":" <> Integer.to_string(account_id)

  defp secrets do
    base = Application.fetch_env!(:sukhi_fedi, :secret_key_base)

    {Plug.Crypto.KeyGenerator.generate(base, "sukhi translate key encryption", length: 32),
     Plug.Crypto.KeyGenerator.generate(base, "sukhi translate key signature", length: 32)}
  end
end
