defmodule CustyardWeb.Admin.SystemHTML do
  @moduledoc "Template for `/admin/system`."

  use CustyardWeb, :html

  import CustyardWeb.BootComponents

  embed_templates "system_html/*"
end
