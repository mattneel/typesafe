defmodule TypeSafe.Assertions do
  @moduledoc false

  # Assertions shared by the data-layer tests for the validation errors the SDK returns.

  import ExUnit.Assertions

  alias TypeSafe.Error

  @doc """
  Asserts `result` is `{:error, %TypeSafe.Error{}}` with the given type, path and message, and
  that the first detail carries the same path. `message` is a string or a regex. Returns the
  error.
  """
  @spec assert_error(term(), Error.type(), [String.t()], String.t() | Regex.t()) :: Error.t()
  def assert_error(result, type, path, message) do
    assert {:error, %Error{type: ^type, path: ^path, details: [%Zoi.Error{path: ^path} | _]} = error} = result
    assert_message(error.message, message)
    error
  end

  @doc "Shorthand for `assert_error/4` with type `:invalid_request`."
  @spec assert_invalid_request(term(), [String.t()], String.t() | Regex.t()) :: Error.t()
  def assert_invalid_request(result, path, message), do: assert_error(result, :invalid_request, path, message)

  @doc "Shorthand for `assert_error/4` with type `:invalid_response`."
  @spec assert_invalid_response(term(), [String.t()], String.t() | Regex.t()) :: Error.t()
  def assert_invalid_response(result, path, message), do: assert_error(result, :invalid_response, path, message)

  defp assert_message(actual, %Regex{} = expected), do: assert(actual =~ expected)
  defp assert_message(actual, expected), do: assert(actual == expected)
end
