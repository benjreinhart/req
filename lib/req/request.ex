defmodule Req.Request do
  @moduledoc ~S"""
  The low-level API and the request struct.

  Req is composed of three main pieces:

    * `Req` - the high-level API

    * `Req.Request` - the low-level API and the request struct (you're here!)

    * `Req.Steps` - the collection of built-in steps

  The low-level API and the request struct is the foundation of Req's extensibility. Virtually all
  of the functionality is broken down into individual pieces - steps. Req works by running the
  request struct through these steps. You can easily reuse or rearrange built-in steps or write new
  ones.

  ## The Low-level API

  Most Req users would use it like this:

      Req.get!("https://api.github.com/repos/elixir-lang/elixir").body["description"]
      #=> "Elixir is a dynamic, functional language designed for building scalable and maintainable applications"

  Here is the equivalent using the low-level API:

      url = "https://api.github.com/repos/elixir-lang/elixir"

      req =
        %Req.Request{method: :get, url: url}
        |> Req.Request.append_request_steps(
          put_user_agent: &Req.Steps.put_user_agent/1,
          # ...
        )
        |> Req.Request.append_response_steps(
          # ...
          decompress_body: &Req.Steps.decompress_body/1,
          decode_body: &Req.Steps.decode_body/1,
          # ...
        )
        |> Req.Request.append_error_steps(
          retry: &Req.Steps.retry/1,
          # ...
        )

      Req.Request.run!(req).body["description"]
      #=> "Elixir is a dynamic, functional language designed for building scalable and maintainable applications"

  By putting the request pipeline yourself you have precise control of exactly what is running and in what order.

  ## The Request Struct

    * `:method` - the HTTP request method

    * `:url` - the HTTP request URL

    * `:headers` - the HTTP request headers

    * `:body` - the HTTP request body

    * `:request_steps` - the list of request steps

    * `:response_steps` - the list of response steps

    * `:error_steps` - the list of error steps

    * `:private` - a map reserved for libraries and frameworks to use.
      Prefix the keys with the name of your project to avoid any future
      conflicts. Only accepts `t:atom/0` keys.

    * `:halted` - whether the request pipeline is halted. See `halt/1`

    * `:adapter` - a request step that makes the actual HTTP request. Defaults to
      `Req.Steps.run_finch/1`. See ["Adapter"](#module-adapter) section below for more information.

  ## Steps

  Req has three types of steps: request, response, and error.

  Request steps are used to refine the data that will be sent to the server.

  After making the actual HTTP request, we'll either get a HTTP response or an error.
  The request, along with the response or error, will go through response or
  error steps, respectively.

  Nothing is actually executed until we run the pipeline with `Req.Request.run/1`.

  ### Request steps

  A request step is a function that accepts a `request` and returns one of the following:

    * A `request`

    * A `{request, response_or_error}` tuple. In that case no further request steps are executed
      and the return value goes through response or error steps

  Examples:

      def put_default_headers(request) do
        update_in(request.headers, &[{"user-agent", "req"} | &1])
      end

      def read_from_cache(request) do
        case ResponseCache.fetch(request) do
          {:ok, response} -> {request, response}
          :error -> request
        end
      end

  ### Response and error steps

  A response step is a function that accepts a `{request, response}` tuple and returns one of the
  following:

    * A `{request, response}` tuple

    * A `{request, exception}` tuple. In that case, no further response steps are executed but the
      exception goes through error steps

  Similarly, an error step is a function that accepts a `{request, exception}` tuple and returns one
  of the following:

    * A `{request, exception}` tuple

    * A `{request, response}` tuple. In that case, no further error steps are executed but the
      response goes through response steps

  Examples:

      def decode({request, response}) do
        case List.keyfind(response.headers, "content-type", 0) do
          {_, "application/json" <> _} ->
            {request, update_in(response.body, &Jason.decode!/1)}

          _ ->
            {request, response}
        end
      end

      def log_error({request, exception}) do
        Logger.error(["#{request.method} #{request.uri}: ", Exception.message(exception)])
        {request, exception}
      end

  ### Halting

  Any step can call `Req.Request.halt/1` to halt the pipeline. This will prevent any further steps
  from being invoked.

  Examples:

      def circuit_breaker(request) do
        if CircuitBreaker.open?() do
          {Req.Request.halt(request), RuntimeError.exception("circuit breaker is open")}
        else
          request
        end
      end

  ## Adapter

  As noted in the ["Request steps"](#module-request-steps) section, a request step besides returning the request,
  might also return `{request, response}` or `{request, exception}`, thus invoking either response or error steps next.
  This is exactly how Req makes the underlying HTTP call, by invoking a request step that follows this contract.

  The default adapter is using Finch via the `Req.Steps.run_finch/1` step.

  Here is a mock adapter that always returns a successful response:

      adapter = fn request ->
        response = %Req.Response{status: 200, body: "it works!"}
        {request, response}
      end

      Req.request!(url: "http://example", adapter: adapter).body
      #=> "it works!"

  And here is a naive Hackney-based implementation:

      hackney = fn request ->
        case :hackney.request(
               request.method,
               URI.to_string(request.url),
               request.headers,
               request.body,
               [:with_body]
             ) do
          {:ok, status, headers, body} ->
            headers = for {name, value} <- headers, do: {String.downcase(name), value}
            response = %Req.Response{status: status, headers: headers, body: body}
            {request, response}

          {:error, reason} ->
            {request, RuntimeError.exception(inspect(reason))}
        end
      end

      Req.get!("https://api.github.com/repos/elixir-lang/elixir", adapter: hackney).body["description"]
      "Elixir is a dynamic, functional language designed for building scalable and maintainable applications"
  """

  @type t() :: %Req.Request{
          method: atom(),
          url: URI.t(),
          headers: [{binary(), binary()}],
          body: iodata(),
          options: map(),
          registered_options: MapSet.t(),
          adapter: request_step(),
          request_steps: [{name :: atom(), request_step()}],
          response_steps: [{name :: atom(), response_step()}],
          error_steps: [{name :: atom(), error_step()}],
          private: map()
        }

  @typep request_step() :: fun()
  @typep response_step() :: fun()
  @typep error_step() :: fun()

  defstruct method: :get,
            url: "",
            headers: [],
            body: "",
            options: %{},
            registered_options: MapSet.new(),
            adapter: &Req.Steps.run_finch/1,
            halted: false,
            request_steps: [],
            response_steps: [],
            error_steps: [],
            private: %{}

  @doc """
  Gets the value for a specific private `key`.
  """
  def get_private(request, key, default \\ nil) when is_atom(key) do
    Map.get(request.private, key, default)
  end

  @doc """
  Assigns a private `key` to `value`.
  """
  def put_private(request, key, value) when is_atom(key) do
    put_in(request.private[key], value)
  end

  @doc """
  Halts the request pipeline preventing any further steps from executing.
  """
  def halt(request) do
    %{request | halted: true}
  end

  @doc false
  @deprecated "Manually build struct instead"
  def build(method, url, options \\ []) do
    %Req.Request{
      method: method,
      url: URI.parse(url),
      headers: Keyword.get(options, :headers, []),
      body: Keyword.get(options, :body, "")
    }
  end

  @doc """
  Appends request steps.

  ## Examples

      iex> Req.Request.append_request_steps(request,
      ...>   noop: fn request -> request end,
      ...>   inspect: &IO.inspect/1
      ...> )
  """
  def append_request_steps(request, steps) do
    update_in(request.request_steps, &(&1 ++ steps))
  end

  @doc """
  Prepends request steps.

  ## Examples

      iex> Req.Request.prepend_request_steps(request,
      ...>   noop: fn request -> request end,
      ...>   inspect: &IO.inspect/1
      ...> )
  """
  def prepend_request_steps(request, steps) do
    update_in(request.request_steps, &(steps ++ &1))
  end

  @doc """
  Appends response steps.

  ## Examples

      iex> Req.Request.append_request_steps(request,
      ...>   noop: fn {request, response} -> {request, response} end,
      ...>   inspect: &IO.inspect/1
      ...> )
  """
  def append_response_steps(request, steps) do
    update_in(request.response_steps, &(&1 ++ steps))
  end

  @doc """
  Prepends response steps.

  ## Examples

      iex> Req.Request.prepend_request_steps(request,
      ...>   noop: fn {request, response} -> {request, response} end,
      ...>   inspect: &IO.inspect/1
      ...> )
  """
  def prepend_response_steps(request, steps) do
    update_in(request.response_steps, &(steps ++ &1))
  end

  @doc """
  Appends error steps.

  ## Examples

      iex> Req.Request.append_error_steps(request,
      ...>   noop: fn {request, exception} -> {request, exception} end,
      ...>   inspect: &IO.inspect/1
      ...> )
  """
  def append_error_steps(request, steps) do
    update_in(request.error_steps, &(&1 ++ steps))
  end

  @doc """
  Prepends error steps.

  ## Examples

      iex> Req.Request.prepend_error_steps(request,
      ...>   noop: fn {request, exception} -> {request, exception} end,
      ...>   inspect: &IO.inspect/1
      ...> )
  """
  def prepend_error_steps(request, steps) do
    update_in(request.error_steps, &(steps ++ &1))
  end

  @doc false
  def prepare(%{request_steps: [step | steps]} = request) do
    case run_step(step, request) do
      %Req.Request{} = request ->
        request = %{request | request_steps: steps}
        prepare(request)

      {_request, %{__exception__: true} = exception} ->
        raise exception
    end
  end

  def prepare(%Req.Request{request_steps: []} = request) do
    request
  end

  @doc """
  Registers an option to be used by a custom step.

  Req ensures that all used options were previously registered which helps
  finding accidentally mistyped option names. If you're adding custom steps
  that are accepting options, call this function to register them.

  ## Examples

      iex> req = Req.new(bas_url: "https://httpbin.org")
      iex> Req.get!(req, url: "/status/201").status
      ** (ArgumentError) unknown option :bas_url. Did you mean :base_url?

      iex> req =
      ...>   Req.new(base_url: "https://httpbin.org")
      ...>   |> Req.Request.register_option(:foo)
      ...>
      iex> Req.get!(req, url: "/status/201", foo: :bar).status
      201
  """
  def register_option(%Req.Request{} = request, option) when is_atom(option) do
    if option in request.registered_options do
      raise "option #{inspect(option)} is already registered"
    else
      update_in(request.registered_options, &MapSet.put(&1, option))
    end
  end

  @doc """
  Runs a request pipeline.

  Returns `{:ok, response}` or `{:error, exception}`.
  """
  def run(request) do
    validate_options(request)
    run_request(request.request_steps, request)
  end

  defp validate_options(request) do
    registered =
      MapSet.union(
        request.registered_options,
        MapSet.new([:method, :url, :headers, :body, :adapter])
      )

    validate_options(Enum.to_list(request.options), registered)
  end

  defp validate_options([{name, _value} | rest], registered) do
    if name in registered do
      validate_options(rest, registered)
    else
      case did_you_mean(Atom.to_string(name), registered) do
        {similar, score} when score > 0.8 ->
          raise ArgumentError, "unknown option #{inspect(name)}. Did you mean :#{similar}?"

        _ ->
          raise ArgumentError, "unknown option #{inspect(name)}"
      end
    end
  end

  defp validate_options([], _registered) do
    :ok
  end

  defp did_you_mean(option, registered) do
    registered
    |> Enum.map(&to_string/1)
    |> Enum.reduce({nil, 0}, &max_similar(&1, option, &2))
  end

  defp max_similar(option, registered, {_, current} = best) do
    score = String.jaro_distance(option, registered)
    if score < current, do: best, else: {option, score}
  end

  defp run_request([step | steps], request) do
    case run_step(step, request) do
      %Req.Request{} = request ->
        run_request(steps, request)

      {%Req.Request{halted: true}, response_or_exception} ->
        result(response_or_exception)

      {request, %Req.Response{} = response} ->
        run_response(request, response)

      {request, %{__exception__: true} = exception} ->
        run_error(request, exception)
    end
  end

  defp run_request([], request) do
    case run_step({:adapter, request.adapter}, request) do
      {request, %Req.Response{} = response} ->
        run_response(request, response)

      {request, %{__exception__: true} = exception} ->
        run_error(request, exception)

      other ->
        raise "expected adapter to return {request, response} or {request, exception}, " <>
                "got: #{inspect(other)}"
    end
  end

  @doc """
  Runs a request pipeline and returns a response or raises an error.

  See `run/1` for more information.
  """
  def run!(request) do
    case run(request) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end

  defp run_response(request, response) do
    steps = request.response_steps

    {_request, response_or_exception} =
      Enum.reduce_while(steps, {request, response}, fn step, {request, response} ->
        case run_step(step, {request, response}) do
          {%Req.Request{halted: true} = request, response_or_exception} ->
            {:halt, {request, response_or_exception}}

          {request, %Req.Response{} = response} ->
            {:cont, {request, response}}

          {request, %{__exception__: true} = exception} ->
            {:halt, run_error(request, exception)}
        end
      end)

    result(response_or_exception)
  end

  defp run_error(request, exception) do
    steps = request.error_steps

    {_request, response_or_exception} =
      Enum.reduce_while(steps, {request, exception}, fn step, {request, exception} ->
        case run_step(step, {request, exception}) do
          {%Req.Request{halted: true} = request, response_or_exception} ->
            {:halt, {request, response_or_exception}}

          {request, %{__exception__: true} = exception} ->
            {:cont, {request, exception}}

          {request, %Req.Response{} = response} ->
            {:halt, run_response(request, response)}
        end
      end)

    result(response_or_exception)
  end

  defp run_step({name, step}, state) when is_atom(name) and is_function(step, 1) do
    step.(state)
  end

  defp result(%Req.Response{} = response) do
    {:ok, response}
  end

  defp result(%{__exception__: true} = exception) do
    {:error, exception}
  end
end
