defmodule CustyardWeb.Operator.SystemHTML do
  @moduledoc "Template for `/operator/system`."

  use CustyardWeb, :html

  import CustyardWeb.BootComponents

  embed_templates "system_html/*"
end
