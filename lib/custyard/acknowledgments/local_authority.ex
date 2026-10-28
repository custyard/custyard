defmodule Custyard.Acknowledgments.LocalAuthority do
  @moduledoc "Explicit tenant capability constructed by local installation-owner commands."
  @enforce_keys [:tenant_id, :channel]
  defstruct [:tenant_id, :channel]
  @type t :: %__MODULE__{tenant_id: integer(), channel: String.t()}
end
