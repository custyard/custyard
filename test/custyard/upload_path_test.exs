defmodule Custyard.UploadPathTest do
  use ExUnit.Case, async: true

  alias Custyard.UploadPath

  test "accepts same-origin /uploads/ paths" do
    assert UploadPath.validate("/uploads/logos/a.png") == :ok
    assert UploadPath.valid?("/uploads/logos/a.png")
  end

  test "rejects external URLs, traversal, encoded traversal, and null bytes" do
    bad_paths = [
      "http://evil",
      "//host/x",
      "/uploads/../secrets",
      "/uploads/%2E%2e/x",
      "/uploads/a%00.png",
      "/uploads/a\0.png",
      "uploads/a.png"
    ]

    for bad <- bad_paths do
      assert {:error, message} = UploadPath.validate(bad),
             "expected #{inspect(bad)} to be rejected"

      assert is_binary(message)
      refute UploadPath.valid?(bad)
    end
  end

  test "rejects non-binary input" do
    assert {:error, _} = UploadPath.validate(nil)
    assert {:error, _} = UploadPath.validate(42)
  end
end
