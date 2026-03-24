%{
  configs: [
    %{
      name: "default",
      strict: false,
      checks: %{
        disabled: [
          # Re-enable as you stabilize
          {Credo.Check.Readability.ModuleDoc, []},
          {Credo.Check.Design.TagTODO, []},
          {Credo.Check.Design.TagFIXME, []}
        ]
      }
    }
  ]
}
