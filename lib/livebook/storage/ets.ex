defmodule Livebook.Storage.Ets do
  @moduledoc """
  Ets implementation of `Livebook.Storage` behaviour.

  The module is supposed to be started just once as it
  is responsible for managing a named ets table.

  `insert` and `delete` operations are supposed to be called using a GenServer
  while all the lookups can be performed by directly accessing the named table.
  """
  @behaviour Livebook.Storage

  use GenServer

  @impl Livebook.Storage
  def all(namespace) do
    :persistent_term.get(__MODULE__)
    |> :ets.match({{namespace, :"$1"}, :"$2", :"$3", :_})
    |> Enum.group_by(
      fn [entity_id, _attr, _val] -> entity_id end,
      fn [_id, attr, val] -> {attr, val} end
    )
    |> Enum.map(fn {entity_id, attributes} ->
      attributes
      |> Map.new()
      |> Map.put(:id, entity_id)
    end)
  end

  @impl Livebook.Storage
  def fetch(namespace, entity_id) do
    :persistent_term.get(__MODULE__)
    |> :ets.lookup({namespace, entity_id})
    |> case do
      [] ->
        :error

      entries ->
        entries
        |> Enum.map(fn {_key, attr, val, _timestamp} -> {attr, val} end)
        |> Map.new()
        |> Map.put(:id, entity_id)
        |> then(&{:ok, &1})
    end
  end

  @impl Livebook.Storage
  def fetch_key(namespace, entity_id, key) do
    :persistent_term.get(__MODULE__)
    |> :ets.match({{namespace, entity_id}, key, :"$1", :_})
    |> case do
      [[value]] -> {:ok, value}
      [] -> :error
    end
  end

  @spec config_file_path() :: Path.t()
  def config_file_path() do
    Path.join([Livebook.Config.data_path(), "livebook.#{Mix.env()}.ets"])
  end

  @impl Livebook.Storage
  def insert(namespace, entity_id, attributes) do
    GenServer.call(__MODULE__, {:insert, namespace, entity_id, attributes})
  end

  @impl Livebook.Storage
  def delete(namespace, entity_id) do
    GenServer.call(__MODULE__, {:delete, namespace, entity_id})
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    # Make sure that this process does not terminate abruptly
    # in case it is persisting to disk. terminate/2 is still a no-op.
    Process.flag(:trap_exit, true)

    file_path = config_file_path()

    # enable passing table name for testing purposes
    table = load_or_create_table(file_path)
    :persistent_term.put(__MODULE__, table)

    {:ok, %{table: table, file_path: file_path}}
  end

  @impl GenServer
  def handle_call({:insert, namespace, entity_id, attributes}, _from, %{table: table} = state) do
    match_head = {{namespace, entity_id}, :"$1", :_, :_}

    guards =
      Enum.map(attributes, fn {key, _val} ->
        {:==, :"$1", key}
      end)

    :ets.select_delete(table, [{match_head, guards, [true]}])

    timestamp = System.os_time(:millisecond)

    attributes =
      Enum.map(attributes, fn {attr, val} ->
        {{namespace, entity_id}, attr, val, timestamp}
      end)

    :ets.insert(table, attributes)

    :ok = save_to_file(state)

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:delete, namespace, entity_id}, _from, %{table: table} = state) do
    :ets.delete(table, {namespace, entity_id})

    :ok = save_to_file(state)

    {:reply, :ok, state}
  end


  defp load_or_create_table(file_path) do
    if File.exists?(file_path) do
      {:ok, tab} = :ets.file2tab(String.to_charlist(file_path))

      tab
    else
      :ets.new(__MODULE__, [:protected, :duplicate_bag])
    end
  end

  defp save_to_file(%{table: table, file_path: file_path}) do
    if is_nil(file_path) do
      :ok
    else
      :ok = :ets.tab2file(table, String.to_charlist(file_path))

      :ok
    end
  end
end
