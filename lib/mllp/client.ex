defmodule MLLP.ClientContract do
  @type error_type :: :connect_failure | :send_error | :recv_error
  @type error_reason :: :closed | :timeout | :no_socket | :inet.posix()

  @type client_error :: MLLP.Client.Error.t()

  @type options :: [
          reply_timeout: non_neg_integer() | :infinity,
          tls_opts: map(),
          socket_opts: map()
        ]

  @type send_options :: %{
          optional(:reply_timeout) => non_neg_integer() | :infinity
        }

  @callback send(
              pid :: pid,
              payload :: HL7.Message.t() | String.t(),
              options :: send_options(),
              timeout :: non_neg_integer()
            ) ::
              {:ok, String.t()}
              | MLLP.Ack.ack_verification_result()
              | {:error, client_error()}

  @callback send_async(
              pid :: pid,
              payload :: HL7.Message.t() | String.t(),
              timeout :: non_neg_integer
            ) ::
              {:ok, :sent}
              | {:error, client_error()}
end

defmodule MLLP.Client do
  use GenServer
  require Logger

  alias MLLP.{Envelope, Ack, ClientContract, TCP, TLS}

  @behaviour ClientContract

  @type pid_ref :: atom | pid | {atom, any} | {:via, atom, any}
  @type ip_address ::
          atom
          | charlist
          | {:local, binary | charlist}
          | {byte, byte, byte, byte}
          | {char, char, char, char, char, char, char, char}

  @type t :: %MLLP.Client{
          socket: any(),
          socket_address: String.t(),
          address: ip_address(),
          port: char(),
          auto_reconnect_interval: non_neg_integer(),
          pending_reconnect: reference() | nil,
          pid: pid() | nil,
          telemetry_module: module() | nil,
          tcp: module() | nil,
          tls_opts: Keyword.t(),
          socket_opts: Keyword.t()
        }

  defstruct socket: nil,
            socket_address: "127.0.0.1:0",
            auto_reconnect_interval: 1000,
            address: {127, 0, 0, 1},
            port: 0,
            pending_reconnect: nil,
            pid: nil,
            telemetry_module: nil,
            tcp: nil,
            connect_failure: nil,
            host_string: nil,
            send_opts: %{},
            tls_opts: [],
            socket_opts: []

  alias __MODULE__, as: State

  ## API 
  @spec format_error(term()) :: String.t()
  def format_error({:tls_alert, _} = err) do
    to_string(:ssl.format_error({:error, err}))
  end

  def format_error(:closed), do: "connection closed"
  def format_error(:timeout), do: "timed out"
  def format_error(:system_limit), do: "all available erlang emulator ports in use"

  def format_error(posix) when is_atom(posix) do
    case :inet.format_error(posix) do
      'unknown POSIX error' ->
        inspect(posix)

      char_list ->
        to_string(char_list)
    end
  end

  def format_error(err) when is_binary(err), do: err

  def format_error(err), do: inspect(err)

  @spec start_link(
          address ::
            :inet.ip4_address()
            | :inet.ip6_address()
            | String.t(),
          port :: non_neg_integer(),
          options :: [keyword()]
        ) :: {:ok, pid()}

  def start_link(address, port, options \\ []) do
    GenServer.start_link(
      __MODULE__,
      [address: normalize_address!(address), port: port] ++ options
    )
  end

  @spec is_connected?(pid :: pid()) :: boolean()
  def is_connected?(pid), do: GenServer.call(pid, :is_connected)

  @spec reconnect(pid :: pid()) :: :ok
  def reconnect(pid), do: GenServer.call(pid, :reconnect)

  @spec send(
          pid :: pid,
          payload :: HL7.Message.t() | String.t() | binary(),
          options :: ClientContract.send_options(),
          timeout :: non_neg_integer()
        ) ::
          {:ok, String.t()}
          | MLLP.Ack.ack_verification_result()
          | {:error, ClientContract.client_error()}

  def send(pid, payload, options \\ %{}, timeout \\ 5000)

  def send(pid, %HL7.Message{} = payload, options, timeout) do
    raw_message = to_string(payload)

    case GenServer.call(pid, {:send, raw_message, options}, timeout) do
      {:ok, reply} ->
        verify_ack(reply, raw_message)

      err ->
        err
    end
  end

  def send(pid, payload, options, timeout) do
    case GenServer.call(pid, {:send, payload, options}, timeout) do
      {:ok, wrapped_message} ->
        {:ok, MLLP.Envelope.unwrap_message(wrapped_message)}

      err ->
        err
    end
  end

  def send_async(pid, payload, timeout \\ 5000)

  def send_async(pid, %HL7.Message{} = payload, timeout) do
    GenServer.call(pid, {:send_async, to_string(payload)}, timeout)
  end

  def send_async(pid, payload, timeout) do
    GenServer.call(pid, {:send_async, payload}, timeout)
  end

  @spec stop(pid :: pid()) :: :ok
  def stop(pid), do: GenServer.stop(pid)

  ## GenServer callbacks
  # ===================
  # GenServer callbacks
  # ===================

  @spec init(Keyword.t()) :: {:ok, MLLP.Client.t(), {:continue, :init_socket}}
  def init(options) do
    opts =
      options
      |> Enum.into(%{tls: []})
      |> validate_options()
      |> maybe_set_default_options()
      |> put_socket_address()

    {:ok, struct(State, opts), {:continue, :init_socket}}
  end

  def handle_continue(:init_socket, state) do
    state1 = attempt_connection(state)
    {:noreply, state1}
  end

  def handle_call(:is_connected, _reply, state) do
    {:reply, (state.socket && !state.pending_reconnect) == true, state}
  end

  def handle_call(:reconnect, _from, state) do
    state1 = stop_connection(state, nil, "reconnect command")
    {:reply, :ok, state1}
  end

  def handle_call(_msg, _from, %State{socket: nil} = state) do
    telemetry(
      :status,
      %{
        status: :disconnected,
        error: :no_socket,
        context: "MLLP.Client disconnected failure"
      },
      state
    )

    err = new_error(:connect, state.connect_failure)
    {:reply, {:error, err}, state}
  end

  def handle_call({:send, message, options}, _from, state) do
    options1 = Map.merge(state.send_opts, options)
    telemetry(:sending, %{}, state)
    payload = MLLP.Envelope.wrap_message(message)

    case state.tcp.send(state.socket, payload) do
      :ok ->
        case state.tcp.recv(state.socket, 0, options1.reply_timeout) do
          {:ok, reply} ->
            telemetry(:received, %{response: reply}, state)
            {:reply, {:ok, reply}, state}

          {:error, reason} ->
            telemetry(
              :status,
              %{
                status: :disconnected,
                error: format_error(reason),
                context: "receive ACK failure"
              },
              state
            )

            new_state = maintain_reconnect_timer(state)
            reply = {:error, new_error(:recv, reason)}
            {:reply, reply, new_state}
        end

      {:error, reason} ->
        telemetry(
          :status,
          %{status: :disconnected, error: format_error(reason), context: "send message failure"},
          state
        )

        new_state = maintain_reconnect_timer(state)
        reply = {:error, new_error(:send, reason)}
        {:reply, reply, new_state}
    end
  end

  def handle_call({:send_async, message}, _from, state) do
    telemetry(:sending, %{}, state)
    payload = MLLP.Envelope.wrap_message(message)

    case state.tcp.send(state.socket, payload) do
      :ok ->
        {:reply, {:ok, :sent}, state}

      {:error, reason} ->
        telemetry(
          :status,
          %{status: :disconnected, error: format_error(reason), context: "send message failure"},
          state
        )

        new_state = maintain_reconnect_timer(state)
        reply = {:error, new_error(:send, reason)}
        {:reply, reply, new_state}
    end
  end

  def handle_info(:timeout, state) do
    new_state =
      state
      |> stop_connection(:timeout, "timeout message")
      |> attempt_connection()

    {:noreply, new_state}
  end

  def handle_info(unknown, state) do
    Logger.warn("Unknown kernel message received => #{inspect(unknown)}")
    {:noreply, state}
  end

  def terminate(reason, state) do
    Logger.error("Client socket terminated. Reason: #{inspect(reason)} State #{inspect(state)}")
    stop_connection(state, reason, "process terminated")
  end

  defp stop_connection(%State{} = state, error, context) do
    if state.socket != nil do
      telemetry(
        :status,
        %{status: :disconnected, error: format_error(error), context: context},
        state
      )

      state.tcp.close(state.socket)
    end

    ensure_pending_reconnect_cancelled(state)
  end

  defp ensure_pending_reconnect_cancelled(%{pending_reconnect: nil} = state), do: state

  defp ensure_pending_reconnect_cancelled(state) do
    :ok = Process.cancel_timer(state.pending_reconnect, info: false)
    %{state | pending_reconnect: nil}
  end

  defp attempt_connection(%State{} = state) do
    telemetry(:status, %{status: :connecting}, state)
    opts = [:binary, {:packet, 0}, {:active, false}] ++ state.socket_opts ++ state.tls_opts

    case state.tcp.connect(state.address, state.port, opts, 2000) do
      {:ok, socket} ->
        state1 = ensure_pending_reconnect_cancelled(state)
        telemetry(:status, %{status: :connected}, state1)
        %{state1 | socket: socket, connect_failure: nil}

      {:error, reason} ->
        message = format_error(reason)
        Logger.error(fn -> "Error connecting to #{state.socket_address} => #{message}" end)

        telemetry(
          :status,
          %{status: :disconnected, error: format_error(reason), context: "connect failure"},
          state
        )

        state
        |> maintain_reconnect_timer()
        |> Map.put(:connect_failure, reason)
    end
  end

  defp maintain_reconnect_timer(state) do
    ref =
      state.pending_reconnect ||
        Process.send_after(self(), :timeout, state.auto_reconnect_interval)

    %State{state | pending_reconnect: ref}
  end

  defp telemetry(_event_name, _measurements, %State{telemetry_module: nil} = _metadata) do
    :ok
  end

  defp telemetry(event_name, measurements, %State{telemetry_module: telemetry_module} = metadata) do
    telemetry_module.execute([:client, event_name], add_timestamps(measurements), metadata)
  end

  defp add_timestamps(measurements) do
    measurements
    |> Map.put(:monotonic, :erlang.monotonic_time())
    |> Map.put(:utc_datetime, DateTime.utc_now())
  end

  defp validate_options(opts) do
    Map.get(opts, :address) || raise "No server address provided to connect to!"
    Map.get(opts, :port) || raise "No server port provdided to connect to!"
    opts
  end

  @default_opts %{
    telemetry_module: MLLP.DefaultTelemetry,
    tls_opts: [],
    socket_opts: []
  }

  @default_send_opts %{
    reply_timeout: :infinity
  }

  defp maybe_set_default_options(opts) do
    socket_module = if opts.tls == [], do: TCP, else: TLS

    send_opts = Map.take(opts, Map.keys(@default_send_opts))

    send_opts = Map.merge(@default_send_opts, send_opts)

    opts
    |> Map.merge(@default_opts)
    |> Map.put_new(:tcp, socket_module)
    |> Map.put(:pid, self())
    |> Map.put(:tls_opts, opts.tls)
    |> Map.put(:send_opts, send_opts)
  end

  defp put_socket_address(%{address: address, port: port} = opts) do
    Map.put(opts, :socket_address, "#{format_address(address)}:#{port}")
  end

  defp format_address(address) when is_list(address) or is_atom(address) or is_binary(address) do
    to_string(address)
  end

  defp format_address(address), do: :inet.ntoa(address)

  defp verify_ack(raw_ack, raw_message) do
    ack = Envelope.unwrap_message(raw_ack)
    unwrapped_message = Envelope.unwrap_message(raw_message)
    Ack.verify_ack_against_message(unwrapped_message, ack)
  end

  defp new_error(context, error) do
    %MLLP.Client.Error{
      reason: error,
      context: context,
      message: format_error(error)
    }
  end

  defp normalize_address!({_, _, _, _} = addr), do: addr
  defp normalize_address!({_, _, _, _, _, _, _, _} = addr), do: addr

  defp normalize_address!(addr) when is_binary(addr) do
    case String.contains?(addr, ".") do
      true ->
        addr
        |> String.to_charlist()
        |> parse_address!()

      false ->
        # hostname
        String.to_charlist(addr)
    end
  end

  defp normalize_address!(addr) when is_list(addr), do: parse_address!(addr)

  defp normalize_address!(addr) when is_atom(addr), do: addr

  defp normalize_address!(addr),
    do: raise(ArgumentError, "Invalid server ip address : #{inspect(addr)}")

  defp parse_address!(addr) do
    case :inet.parse_address(addr) do
      {:error, _} ->
        raise ArgumentError, "Invalid server ip address : #{inspect(addr)}"

      {:ok, valid} ->
        valid
    end
  end
end
