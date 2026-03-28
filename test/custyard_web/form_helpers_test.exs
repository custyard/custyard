defmodule CustyardWeb.FormHelpersTest do
  use ExUnit.Case, async: true

  alias CustyardWeb.FormHelpers

  describe "format_error/1" do
    test "formats simple error message" do
      assert FormHelpers.format_error({"can't be blank", []}) == "can't be blank"
    end

    test "interpolates count in error message" do
      error = {"should be at least %{count} character(s)", [count: 8]}

      assert FormHelpers.format_error(error) == "should be at least 8 character(s)"
    end

    test "interpolates multiple values" do
      error = {"must be between %{min} and %{max}", [min: 1, max: 100]}

      assert FormHelpers.format_error(error) == "must be between 1 and 100"
    end

    test "handles validation type metadata" do
      # Error tuples often include validation type that should be interpolated away
      error = {"is invalid", [validation: :format]}

      assert FormHelpers.format_error(error) == "is invalid"
    end

    test "converts non-string values to strings" do
      error = {"must be greater than %{number}", [number: 42.5]}

      assert FormHelpers.format_error(error) == "must be greater than 42.5"
    end
  end

  describe "format_changeset_errors/1" do
    test "formats single field error" do
      changeset = %Ecto.Changeset{
        valid?: false,
        errors: [name: {"can't be blank", [validation: :required]}]
      }

      assert FormHelpers.format_changeset_errors(changeset) == "name: can't be blank"
    end

    test "formats multiple errors on same field" do
      changeset = %Ecto.Changeset{
        valid?: false,
        errors: [
          password: {"is too short", [count: 8, validation: :length]},
          password: {"must contain a number", [validation: :format]}
        ]
      }

      result = FormHelpers.format_changeset_errors(changeset)

      # Multiple errors on same field are joined with comma
      assert result == "password: is too short, must contain a number"
    end

    test "formats errors on multiple fields" do
      changeset = %Ecto.Changeset{
        valid?: false,
        errors: [
          name: {"can't be blank", [validation: :required]},
          email: {"has invalid format", [validation: :format]}
        ]
      }

      result = FormHelpers.format_changeset_errors(changeset)

      # Different fields are separated by semicolons
      assert result =~ "name: can't be blank"
      assert result =~ "email: has invalid format"
      assert result =~ "; "
    end

    test "handles empty errors" do
      changeset = %Ecto.Changeset{valid?: true, errors: []}

      assert FormHelpers.format_changeset_errors(changeset) == ""
    end

    test "interpolates values in changeset errors" do
      changeset = %Ecto.Changeset{
        valid?: false,
        errors: [
          username: {"should be at least %{count} character(s)", [count: 3, validation: :length]}
        ]
      }

      result = FormHelpers.format_changeset_errors(changeset)

      assert result == "username: should be at least 3 character(s)"
    end
  end
end
