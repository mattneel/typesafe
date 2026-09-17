defmodule TypeSafe.ClientConfigTest do
  # Resolution reads environment variables and application config, which are global to the VM,
  # so this module runs synchronously and restores both (and `Req.default_options/0`) after
  # every test.
  use ExUnit.Case, async: false

  import TypeSafe.TransportHelpers

  alias TypeSafe.Retry

  @moduletag :capture_log

  @env_vars ~w(TYPESAFE_API_KEY TYPESAFE_BASE_URL TYPESAFE_DEFAULT_MODEL TYPESAFE_MODEL TYPESAFE_TIMEOUT)

  setup do
    saved_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    saved_config = Application.get_all_env(:typesafe)
    saved_req_defaults = Req.default_options()

    Enum.each(@env_vars, &System.delete_env/1)
    Enum.each(saved_config, fn {key, _value} -> Application.delete_env(:typesafe, key) end)

    on_exit(fn ->
      Enum.each(saved_env, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)

      :typesafe
      |> Application.get_all_env()
      |> Enum.each(fn {key, _value} -> Application.delete_env(:typesafe, key) end)

      Enum.each(saved_config, fn {key, value} -> Application.put_env(:typesafe, key, value) end)
      Req.default_options(saved_req_defaults)
    end)
  end

  describe "api_key" do
    test "an explicit option wins over the environment and config" do
      System.put_env("TYPESAFE_API_KEY", "ts_env")
      Application.put_env(:typesafe, :api_key, "ts_config")

      assert TypeSafe.new(api_key: "ts_option").api_key == "ts_option"
    end

    test "TYPESAFE_API_KEY wins over config and is trimmed" do
      System.put_env("TYPESAFE_API_KEY", "  ts_env\n")
      Application.put_env(:typesafe, :api_key, "ts_config")

      assert TypeSafe.new().api_key == "ts_env"
    end

    test "config is used when neither the option nor the environment is set" do
      Application.put_env(:typesafe, :api_key, "ts_config")

      assert TypeSafe.new().api_key == "ts_config"
    end

    test "an explicit nil counts as absent" do
      System.put_env("TYPESAFE_API_KEY", "ts_env")

      assert TypeSafe.new(api_key: nil).api_key == "ts_env"
    end

    test "a blank TYPESAFE_API_KEY is ignored" do
      System.put_env("TYPESAFE_API_KEY", "   ")
      Application.put_env(:typesafe, :api_key, "ts_config")

      assert TypeSafe.new().api_key == "ts_config"
    end

    test "a missing key raises ArgumentError naming every source" do
      System.put_env("TYPESAFE_API_KEY", "")

      error = assert_raise ArgumentError, fn -> TypeSafe.new(model: "jev-latest") end

      assert error.message =~ "no TypeSafe API key"
      assert error.message =~ ":api_key"
      assert error.message =~ "TYPESAFE_API_KEY"
      assert error.message =~ "config :typesafe, api_key:"
    end
  end

  describe "base_url" do
    test "resolves option, then TYPESAFE_BASE_URL, then config, then the default" do
      assert TypeSafe.new(api_key: "k").base_url == "https://api.typesafe.ai"

      Application.put_env(:typesafe, :base_url, "https://config.example.com")
      assert TypeSafe.new(api_key: "k").base_url == "https://config.example.com"

      System.put_env("TYPESAFE_BASE_URL", " https://env.example.com/typesafe/ ")
      assert TypeSafe.new(api_key: "k").base_url == "https://env.example.com/typesafe"

      assert TypeSafe.new(api_key: "k", base_url: "https://option.example.com").base_url ==
               "https://option.example.com"
    end

    test "a blank TYPESAFE_BASE_URL is ignored" do
      System.put_env("TYPESAFE_BASE_URL", "\t")

      assert TypeSafe.new(api_key: "k").base_url == "https://api.typesafe.ai"
    end

    test "an invalid TYPESAFE_BASE_URL raises ArgumentError" do
      System.put_env("TYPESAFE_BASE_URL", "api.typesafe.ai")

      assert_raise ArgumentError, ~r/expected an http\(s\) URL/, fn -> TypeSafe.new(api_key: "k") end
    end
  end

  describe "model" do
    test "resolves option, then TYPESAFE_DEFAULT_MODEL, then config, then the default" do
      System.put_env("TYPESAFE_MODEL", "ignored-model")
      assert TypeSafe.new(api_key: "k").model == "jev-latest"

      Application.put_env(:typesafe, :model, "jev-config")
      assert TypeSafe.new(api_key: "k").model == "jev-config"

      System.put_env("TYPESAFE_DEFAULT_MODEL", "jev-env ")
      assert TypeSafe.new(api_key: "k").model == "jev-env"

      assert TypeSafe.new(api_key: "k", model: "jev-option").model == "jev-option"
    end
  end

  describe "options without environment variables" do
    test "timeout, retry, headers and finch come from config unless given explicitly" do
      System.put_env("TYPESAFE_TIMEOUT", "1")
      Application.put_env(:typesafe, :timeout, 2_500)
      Application.put_env(:typesafe, :retry, max_retries: 5)
      Application.put_env(:typesafe, :headers, %{"x-team" => "config"})
      Application.put_env(:typesafe, :finch, name: MyApp.ConfigFinch)

      client = TypeSafe.new(api_key: "k")
      assert client.timeout == 2_500
      assert client.retry == %Retry{max_retries: 5}
      assert client.headers == [{"x-team", "config"}]
      assert client.finch == [name: MyApp.ConfigFinch]

      client =
        TypeSafe.new(
          api_key: "k",
          timeout: 900,
          retry: false,
          headers: [{"x-team", "option"}],
          finch: [name: MyApp.OptionFinch]
        )

      assert client.timeout == 900
      assert client.retry == false
      assert client.headers == [{"x-team", "option"}]
      assert client.finch == [name: MyApp.OptionFinch]
    end

    test "invalid config values raise ArgumentError from new/1" do
      Application.put_env(:typesafe, :timeout, "10s")

      assert_raise ArgumentError, ~r/invalid TypeSafe options: .*timeout/, fn -> TypeSafe.new(api_key: "k") end
    end

    test "unrelated config keys are ignored" do
      Application.put_env(:typesafe, :log_level, :debug)

      assert %TypeSafe.Client{} = TypeSafe.new(api_key: "k")
    end
  end

  describe "req_options" do
    test "config and explicit values are merged, the explicit value winning per key" do
      Application.put_env(:typesafe, :req_options,
        plug: {Req.Test, TypeSafe},
        receive_timeout: 1,
        retry_log_level: :info
      )

      client = TypeSafe.new(api_key: "k", req_options: [receive_timeout: 2, redirect: false])

      assert Keyword.fetch!(client.req_options, :plug) == {Req.Test, TypeSafe}
      assert Keyword.fetch!(client.req_options, :receive_timeout) == 2
      assert Keyword.fetch!(client.req_options, :retry_log_level) == :info
      assert Keyword.fetch!(client.req_options, :redirect) == false
      assert client.req.options.plug == {Req.Test, TypeSafe}
      assert client.req.options.receive_timeout == 2
    end

    test "config alone is used when no explicit value is given" do
      Application.put_env(:typesafe, :req_options, plug: {Req.Test, TypeSafe})

      assert TypeSafe.new(api_key: "k").req_options == [plug: {Req.Test, TypeSafe}]
    end

    test "an invalid config value raises ArgumentError" do
      Application.put_env(:typesafe, :req_options, :plug)

      assert_raise ArgumentError, ~r/req_options/, fn -> TypeSafe.new(api_key: "k", req_options: [redirect: false]) end
    end

    test "the documented test configuration routes calls through Req.Test" do
      Application.put_env(:typesafe, :api_key, "ts_config_key")
      Application.put_env(:typesafe, :retry, false)
      Application.put_env(:typesafe, :req_options, plug: {Req.Test, TypeSafe})
      capture_requests(&json(&1, 200, noul_body()))

      assert {:ok, %TypeSafe.Response{}} = TypeSafe.ask(TypeSafe.new(), "state", noul_question())
      assert receive_request().headers["authorization"] == ["Bearer ts_config_key"]
    end
  end

  describe "resolution time" do
    test "options resolve once, when the client is built" do
      Application.put_env(:typesafe, :req_options, plug: {Req.Test, TypeSafe})
      System.put_env("TYPESAFE_API_KEY", "ts_first")
      client = TypeSafe.new(retry: false)

      System.put_env("TYPESAFE_API_KEY", "ts_second")
      System.put_env("TYPESAFE_BASE_URL", "https://changed.example.com")
      System.put_env("TYPESAFE_DEFAULT_MODEL", "jev-changed")
      capture_requests(&json(&1, 200, noul_body()))

      assert {:ok, _response} = TypeSafe.ask(client, "state", noul_question())

      request = receive_request()
      assert request.host == "api.typesafe.ai"
      assert request.headers["authorization"] == ["Bearer ts_first"]
      assert request.json["model"] == "jev-latest"
    end
  end

  describe "TypeSafe.Req.attach/2" do
    test "resolves the API key and model from the environment" do
      System.put_env("TYPESAFE_API_KEY", "ts_env")
      System.put_env("TYPESAFE_DEFAULT_MODEL", "jev-env")
      capture_requests(&json(&1, 200, noul_body()))

      req = [plug: {Req.Test, TypeSafe}] |> Req.new() |> TypeSafe.Req.attach(retry: false)

      assert {:ok, %Req.Response{status: 200}} =
               Req.post(req, typesafe_state: "state", typesafe_questions: noul_question())

      request = receive_request()
      assert request.headers["authorization"] == ["Bearer ts_env"]
      assert request.json["model"] == "jev-env"
    end

    test "resolves the API key from config" do
      Application.put_env(:typesafe, :api_key, "ts_config")
      capture_requests(&json(&1, 200, noul_body()))

      req = [plug: {Req.Test, TypeSafe}] |> Req.new() |> TypeSafe.Req.attach(retry: false)

      refute Map.has_key?(req.options, :auth)
      assert {:ok, _response} = Req.post(req, typesafe_state: "state", typesafe_questions: noul_question())
      assert receive_request().headers["authorization"] == ["Bearer ts_config"]
    end

    test "raises ArgumentError without an API key" do
      assert_raise ArgumentError, ~r/no TypeSafe API key/, fn -> TypeSafe.Req.attach(Req.new()) end
    end

    test "base_url resolves option, then TYPESAFE_BASE_URL, then config, then the default" do
      capture_requests(&json(&1, 200, noul_body()))
      request = Req.new(base_url: "https://proxy.internal/app", plug: {Req.Test, TypeSafe})

      assert typesafe_host(request, api_key: "k") == "api.typesafe.ai"

      Application.put_env(:typesafe, :base_url, "https://config.example.com")
      assert typesafe_host(request, api_key: "k") == "config.example.com"

      System.put_env("TYPESAFE_BASE_URL", "https://env.example.com/")
      assert typesafe_host(request, api_key: "k") == "env.example.com"

      assert typesafe_host(request, api_key: "k", base_url: "https://option.example.com") == "option.example.com"
    end

    test "a blank TYPESAFE_BASE_URL is ignored" do
      System.put_env("TYPESAFE_BASE_URL", "  ")
      capture_requests(&json(&1, 200, noul_body()))
      request = Req.new(base_url: "https://proxy.internal/app", plug: {Req.Test, TypeSafe})

      assert typesafe_host(request, api_key: "k") == "api.typesafe.ai"
    end

    test "a :retry_delay from Req.default_options/0 does not break the retry policy" do
      Req.default_options(retry_delay: fn _count -> 0 end)
      Req.Test.expect(TypeSafe, &json(&1, 503, %{"detail" => "Service Unavailable"}))
      Req.Test.expect(TypeSafe, &json(&1, 200, noul_body()))

      assert {:ok, %TypeSafe.Response{}} =
               [plug: {Req.Test, TypeSafe}]
               |> Req.new()
               |> TypeSafe.Req.attach(api_key: "k", retry: [backoff_initial_ms: 0])
               |> Req.post(typesafe_state: "state", typesafe_questions: noul_question())
               |> TypeSafe.Req.decode(noul_question())

      Req.Test.verify!(TypeSafe)
    end
  end

  describe "Req.default_options/1" do
    test "a global :retry_delay is dropped from the client, so the policy's delays apply" do
      Req.default_options(retry_delay: fn _count -> 0 end)
      Req.Test.expect(TypeSafe, &json(&1, 503, %{"detail" => "Service Unavailable"}))
      Req.Test.expect(TypeSafe, &json(&1, 200, noul_body()))

      client =
        TypeSafe.new(api_key: "k", retry: [backoff_initial_ms: 0], req_options: [plug: {Req.Test, TypeSafe}])

      refute Map.has_key?(client.req.options, :retry_delay)
      assert {:ok, %TypeSafe.Response{}} = TypeSafe.ask(client, "state", noul_question())
      Req.Test.verify!(TypeSafe)
    end

    test "a global :finch pool works with clients and per-call timeouts" do
      base_url = start_http_server(200, noul_body())
      finch = :"typesafe_config_test_finch_#{System.unique_integer([:positive])}"
      start_supervised!({Finch, name: finch})
      Req.default_options(finch: [name: finch])

      client = TypeSafe.new(api_key: "k", base_url: base_url, retry: false)

      assert client.req.options.finch == [name: finch]
      assert {:ok, %TypeSafe.Response{}} = TypeSafe.ask(client, "state", noul_question())
      assert {:ok, %TypeSafe.Response{}} = TypeSafe.ask(client, "state", noul_question(), timeout: 2_345)
    end

    test "per-call timeouts start no Finch pools" do
      client = TypeSafe.new(api_key: "k", base_url: start_http_server(200, noul_body()), retry: false)
      assert {:ok, %TypeSafe.Response{}} = TypeSafe.ask(client, "state", noul_question())
      pools = DynamicSupervisor.count_children(Req.FinchSupervisor).active

      for timeout <- 5_000..5_009 do
        assert {:ok, %TypeSafe.Response{}} = TypeSafe.ask(client, "state", noul_question(), timeout: timeout)
      end

      assert DynamicSupervisor.count_children(Req.FinchSupervisor).active == pools
    end
  end

  defp typesafe_host(request, opts) do
    {:ok, _response} =
      request
      |> TypeSafe.Req.attach(Keyword.put(opts, :retry, false))
      |> Req.post(typesafe_state: "state", typesafe_questions: noul_question())

    receive_request().host
  end
end
