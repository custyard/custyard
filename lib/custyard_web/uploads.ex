defmodule CustyardWeb.Uploads do
  @moduledoc """
  Filesystem helpers for operator-uploaded logo files.

  Files are stored under the configured `:upload_dir` (see `config :custyard,
  :upload_dir`) in a `logos/` subdirectory with unguessable UUID filenames,
  and are served publicly from `/uploads/` by `CustyardWeb.Plugs.UploadedFiles`.

  This mirrors the storage mechanism used for organization logos in
  `CustyardWeb.Operator.OrganizationsLive` so instance and organization
  branding share one storage location.
  """

  @doc """
  Copy an uploaded temp file into the logos upload directory under a unique
  UUID filename, preserving the original extension.

  Returns the public `/uploads/logos/...` path suitable for persisting via
  `Custyard.Settings.update_branding/1` (validated by `Custyard.UploadPath`).
  """
  def save_logo(temp_path, client_name) do
    ext = Path.extname(client_name)
    filename = "#{Ecto.UUID.generate()}#{ext}"
    dest_dir = Path.join(upload_dir(), "logos")
    File.mkdir_p!(dest_dir)
    File.cp!(temp_path, Path.join(dest_dir, filename))
    "/uploads/logos/#{filename}"
  end

  @doc """
  Delete a previously saved logo by its public `/uploads/logos/...` path.

  Anything that is not a plain filename directly under the logos directory
  (including traversal attempts) is ignored, as are non-logo paths.
  """
  def delete_logo("/uploads/logos/" <> filename) do
    if filename != "" and Path.basename(filename) == filename do
      File.rm(Path.join([upload_dir(), "logos", filename]))
    else
      :ok
    end
  end

  def delete_logo(_), do: :ok

  defp upload_dir, do: Application.get_env(:custyard, :upload_dir)
end
