defmodule CustyardWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  Custom templates exist for 404 and 500 errors (see error_html/ directory).
  For other error codes, Phoenix returns a plain text status message.
  """
  use CustyardWeb, :html

  # Embed custom error templates (404.html.heex, 500.html.heex)
  # These are compiled into render/2 functions at compile time.
  embed_templates "error_html/*"
end
