defmodule CustyardWeb.IntakeHTML do
  @moduledoc """
  Templates for the public intake pages.

  `active.html.heex` and `passive.html.heex` are the two page modes;
  `message_form.html.heex` and `resume_banner.html.heex` embed as shared
  function components.
  """

  use CustyardWeb, :html

  embed_templates "intake_html/*"
end
