defmodule Compos.Core.Google.Store do
  @moduledoc """
  Private encrypted token files. The local key and directory require the OS user.
  This protects backups of token files; it is not an OS keychain or user sandbox.
  """
  defp root, do: Path.join(Compos.Core.home(), "google")

  defp path(id),
    do: Path.join(root(), Base.encode16(:crypto.hash(:sha256, id), case: :lower) <> ".token")

  def accounts do
    Path.wildcard(Path.join(root(), "*.token"))
    |> Enum.flat_map(fn path ->
      case decode(path) do
        {:ok, record} -> [Map.take(record, ["id", "email", "scopes"])]
        _ -> []
      end
    end)
    |> Enum.sort_by(& &1["email"])
  end

  def read(id) when is_binary(id), do: decode(path(id))
  def read(_), do: {:error, "Select a connected Google account."}
  def delete(id), do: File.rm(path(id))

  def write(id, record) do
    with {:ok, key} <- key() do
      iv = :crypto.strong_rand_bytes(12)

      {cipher, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          key,
          iv,
          Jason.encode!(record),
          "compos-google-v1",
          true
        )

      private_write(path(id), <<1, iv::binary, tag::binary, cipher::binary>>)
    end
  rescue
    _ -> {:error, "Could not save Google credentials."}
  end

  defp decode(path) do
    with {:ok, <<1, iv::binary-size(12), tag::binary-size(16), cipher::binary>>} <-
           File.read(path),
         {:ok, key} <- File.read(Path.join(root(), "key")),
         plain when is_binary(plain) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             iv,
             cipher,
             "compos-google-v1",
             tag,
             false
           ),
         {:ok, record} <- Jason.decode(plain) do
      {:ok, record}
    else
      _ -> {:error, "Google account is unavailable. Connect it with M-x google-connect."}
    end
  rescue
    _ -> {:error, "Google credentials could not be read. Reconnect this account."}
  end

  defp key do
    :global.trans({{__MODULE__, :key}, self()}, fn ->
      File.mkdir_p!(root())
      File.chmod!(root(), 0o700)
      path = Path.join(root(), "key")

      case File.read(path) do
        {:ok, key} when byte_size(key) == 32 ->
          {:ok, key}

        {:error, :enoent} ->
          key = :crypto.strong_rand_bytes(32)
          with :ok <- private_write(path, key), do: {:ok, key}

        _ ->
          {:error, "Google credential key is invalid."}
      end
    end)
  end

  defp private_write(path, bytes) do
    tmp = path <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    try do
      with {:ok, file} <- File.open(tmp, [:write, :binary, :exclusive]) do
        try do
          File.chmod!(tmp, 0o600)
          :ok = IO.binwrite(file, bytes)
          :ok = :file.sync(file)
        after
          File.close(file)
        end

        File.rename(tmp, path)
      end
    after
      File.rm(tmp)
    end
  end
end
