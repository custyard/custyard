# Fix Message Schema Type Error

## Issue
The `Custyard.Message` schema has an invalid field type that prevents compilation.

## Location
`lib/custyard/message.ex:10`

## Problem
```elixir
field :body, :text
```

Ecto does not have a `:text` type. The valid types are `:string`, `:binary`, etc.

## Fix
Change `:text` to `:string`:
```elixir
field :body, :string
```

Note: The database migration may use `text` type for the column (for longer content), but the Ecto schema type should be `:string` regardless.

## Compilation Error
```
** (ArgumentError) unknown type :text for field :body
```
