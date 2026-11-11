defmodule CustyardWeb.BootHTML do
  @moduledoc """
  The four boot cards (docs/backlog/1103-first-run-experience.md):
  `unconfigured`, `starting`, `database_unavailable` and `first_run`. Dead views rendered
  through `CustyardWeb.Layouts.boot_root/1`, never through the router.
  """

  use CustyardWeb, :html

  import CustyardWeb.BootComponents

  embed_templates "boot_html/*"
end
