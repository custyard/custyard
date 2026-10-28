defmodule Custyard.DataSubjects.LocalAuthority do
  @moduledoc "Explicit capability used only by the local installation-owner DSAR command."
  @enforce_keys [:tenant_id]
  defstruct [:tenant_id]
  @type t :: %__MODULE__{tenant_id: integer()}
end
