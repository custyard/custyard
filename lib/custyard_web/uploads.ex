defmodule CustyardWeb.Uploads do
  @moduledoc """
  Tenant logos uploaded by staff.

  A logo is stored in the application database through `Custyard.Files`, as a
  `:logo` file owned by the tenant, so it needs no disk volume. Its public
  path is `/uploads/logos/<uuid><ext>`: that is what `tenants.logo_url` holds
  (validated by `Custyard.UploadPath`) and what
  `CustyardWeb.Plugs.UploadedFiles` serves without a session. The UUID is the
  only thing protecting a logo that no page shows yet.

  The stored file's key is the filename part of that path with the extension
  lowercased (`logo_key/1`). Earlier releases wrote logos to disk under the
  same filenames, so a logo imported from there keeps its path.
  """

  alias Custyard.Files

  @logo_prefix "/uploads/logos/"
  @logo_extensions ~w(.png .jpg .jpeg .svg .webp)
  @max_logo_bytes 2_000_000

  @doc "File extensions a logo upload may have, lowercase with the dot."
  @spec logo_extensions() :: [String.t()]
  def logo_extensions, do: @logo_extensions

  @doc "Largest logo accepted, in bytes."
  @spec max_logo_bytes() :: pos_integer
  def max_logo_bytes, do: @max_logo_bytes

  @doc """
  Stores an uploaded temp file as a logo of the tenant under a new UUID key
  and returns its public `/uploads/logos/...` path.

  `client_name` only supplies the extension. The upload form already limits
  extension and size; they are checked again here so nothing else can store
  an arbitrary file as a logo. `{:error, :not_accepted}` means the extension
  is not one of `logo_extensions/0`, `{:error, :too_large}` that the file is
  over `max_logo_bytes/0`. Nothing is stored for a refused file.
  """
  @spec save_logo(tenant_id :: integer, temp_path :: Path.t(), client_name :: String.t()) ::
          {:ok, String.t()} | {:error, :not_accepted | :too_large}
  def save_logo(tenant_id, temp_path, client_name) when is_integer(tenant_id) do
    ext = client_name |> Path.extname() |> String.downcase(:ascii)

    cond do
      ext not in @logo_extensions ->
        {:error, :not_accepted}

      # Checked before reading, so an oversized file never enters memory.
      File.stat!(temp_path).size > @max_logo_bytes ->
        {:error, :too_large}

      true ->
        key = Ecto.UUID.generate() <> ext
        {:ok, _file} = Files.put(tenant_id, :logo, key, File.read!(temp_path))
        {:ok, @logo_prefix <> key}
    end
  end

  @doc """
  Removes the tenant's logo stored for a public `/uploads/logos/...` path.

  Only a file of that tenant is removed: a path naming another tenant's logo
  leaves it in place. Any other path, and a filename that is not a valid key,
  is ignored.
  """
  @spec delete_logo(tenant_id :: integer, path :: term) :: :ok
  def delete_logo(tenant_id, @logo_prefix <> filename) when is_integer(tenant_id) do
    case logo_key(filename) do
      {:ok, key} -> Files.delete(tenant_id, :logo, key)
      :error -> :ok
    end
  end

  def delete_logo(_tenant_id, _path), do: :ok

  @doc """
  The stored-file key for the filename part of a logo path: the filename with
  its extension lowercased. `:error` when that is not a key `Custyard.Files`
  accepts, which rules out subdirectories and empty names.
  """
  @spec logo_key(filename :: String.t()) :: {:ok, String.t()} | :error
  def logo_key(filename) when is_binary(filename) do
    ext = Path.extname(filename)
    key = String.replace_suffix(filename, ext, String.downcase(ext, :ascii))

    # The rule Custyard.Files.put/4 applies to a key.
    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,254}\z/, key), do: {:ok, key}, else: :error
  end
end
