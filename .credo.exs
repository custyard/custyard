%{
  configs: [
    %{
      name: "default",
      strict: false,
      checks: [
        # Disable checks that conflict with project style - re-enable incrementally
        {Credo.Check.Readability.ModuleDoc, false},
        {Credo.Check.Design.TagTODO, false},
        {Credo.Check.Design.TagFIXME, false},
        # Temporarily disabled during quality audit
        {Credo.Check.Refactor.Nesting, false},
        {Credo.Check.Readability.AliasOrder, false},
        {Credo.Check.Refactor.WithClauses, false},
        {Credo.Check.Readability.PredicateFunctionNames, false},
        {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, false}
      ]
    }
  ]
}
