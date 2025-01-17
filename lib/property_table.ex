defmodule PropertyTable do
  @moduledoc File.read!("README.md")
             |> String.split("<!-- MODULEDOC -->")
             |> Enum.fetch!(1)

  alias PropertyTable.Updater

  @typedoc """
  A table_id identifies a group of properties
  """
  @type table_id() :: atom()

  @typedoc """
  Properties
  """
  @type property() :: any()
  @type pattern() :: any()
  @type value() :: any()
  @type property_value() :: {property(), value()}

  @typedoc """
  PropertyTable configuration options

  See `start_link/2` for usage.
  """
  @type option() ::
          {:name, table_id()} | {:properties, [property_value()]} | {:tuple_events, boolean()}

  @doc """
  Start a PropertyTable's supervision tree

  To create a PropertyTable for your application or library, add the following
  `child_spec` to one of your supervision trees:

  ```elixir
  {PropertyTable, name: MyTableName}
  ```

  The `:name` option is required. All calls to `PropertyTable` will need to
  know it and the process will be registered under than name so be sure it's
  unique.

  Additional options are:

  * `:properties` - a list of `{property, value}` tuples to initially populate
    the `PropertyTable`
  * `:matcher` - set the format for how properties and how they should be
    matched for triggering events. See `PropertyTable.Matcher`.
  * `:tuple_events` - set to `true` for change events to be in the old tuple
    format. This is not recommended for new code and hopefully will be removed
    in the future.

  Persistent options:

  * You MUST set at least `:persist_data_path` for any of the other options to be respected!
  * If the table can restore its data from disk, it will IGNORE your initial `:properties` value.

  * `:persist_data_path` - set to a directory where PropertyTable will
    persist the contents of the table to disk, snapshots will also be stored here.
  * `:persist_interval` - if set PropertyTable will persist the contents of
    tables to disk in intervals of the provided value (in milliseconds) automatically.
  * `:persist_max_snapshots` - Maximum number of manual snapshots to keep on disk before they
    are replaced - (oldest snapshots are replaced first.) Defaults to 25.
  * `:persist_compression` - `0..9` range to compress the terms when written to disk, see `:erlang.term_to_binary/2`. Defaults to 6.
  """
  @spec start_link([option()]) :: Supervisor.on_start()
  def start_link(options) do
    name =
      case Keyword.fetch(options, :name) do
        {:ok, name} when is_atom(name) ->
          name

        {:ok, other} ->
          raise ArgumentError, "expected :name to be an atom, got: #{inspect(other)}"

        :error ->
          raise ArgumentError, "expected :name option to be present"
      end

    tuple_events = Keyword.get(options, :tuple_events, false)

    unless is_boolean(tuple_events) do
      raise ArgumentError, "expected :tuple_events to be boolean, got: #{inspect(tuple_events)}"
    end

    matcher = Keyword.get(options, :matcher, PropertyTable.Matcher.StringPath)

    unless is_atom(matcher) do
      raise ArgumentError, "expected :matcher to be module, got: #{inspect(matcher)}"
    end

    properties = Keyword.get(options, :properties, [])

    unless Enum.all?(properties, fn {k, _} -> matcher.check_property(k) == :ok end) do
      raise ArgumentError,
            "expected :properties to contain valid properties, got: #{inspect(properties)}"
    end

    persistence_options = maybe_get_persistence_options(options)

    Supervisor.start_link(
      __MODULE__.Supervisor,
      %{
        table: name,
        properties: properties,
        tuple_events: tuple_events,
        matcher: matcher,
        persistence_options: persistence_options
      },
      name: name
    )
  end

  @doc """
  Returns a specification to start a property_table under a supervisor.
  See `Supervisor`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, PropertyTable),
      start: {PropertyTable, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Subscribe to receive events
  """
  @spec subscribe(table_id(), pattern()) :: :ok
  def subscribe(table, pattern) do
    registry = PropertyTable.Supervisor.registry_name(table)
    {:ok, matcher} = Registry.meta(registry, :matcher)

    case matcher.check_pattern(pattern) do
      :ok ->
        {:ok, _} = Registry.register(registry, :subscriptions, pattern)
        :ok

      {:error, error} ->
        raise error
    end
  end

  @doc """
  Stop subscribing to a property
  """
  @spec unsubscribe(table_id(), pattern()) :: :ok
  def unsubscribe(table, pattern) do
    registry = PropertyTable.Supervisor.registry_name(table)
    Registry.unregister_match(registry, :subscriptions, pattern)
  end

  @doc """
  Get the current value of a property
  """
  @spec get(table_id(), property(), value()) :: value()
  def get(table, property, default \\ nil) do
    case :ets.lookup(table, property) do
      [{_property, value, _timestamp}] -> value
      [] -> default
    end
  end

  @doc """
  Fetch a property with the time that it was set

  Timestamps come from `System.monotonic_time()`
  """
  @spec fetch_with_timestamp(table_id(), property()) :: {:ok, value(), integer()} | :error
  def fetch_with_timestamp(table, property) do
    case :ets.lookup(table, property) do
      [{_property, value, timestamp}] -> {:ok, value, timestamp}
      [] -> :error
    end
  end

  @doc """
  Get all properties

  This function might return a really long list so it's mainly intended for
  debug or convenience when you know that the table only contains a few
  properties.
  """
  @spec get_all(table_id()) :: [{property(), value()}]
  def get_all(table) do
    :ets.foldl(
      fn {property, value, _timestamp}, acc -> [{property, value} | acc] end,
      [],
      table
    )
  end

  @doc """
  Get a list of all properties matching the specified property pattern
  """
  @spec match(table_id(), pattern()) :: [{property(), value()}]
  def match(table, pattern) do
    registry = PropertyTable.Supervisor.registry_name(table)
    {:ok, matcher} = Registry.meta(registry, :matcher)

    :ets.foldl(
      fn {property, value, _timestamp}, acc ->
        if matcher.matches?(pattern, property) do
          [{property, value} | acc]
        else
          acc
        end
      end,
      [],
      table
    )
  end

  @doc """
  Update a property and notify listeners
  """
  @spec put(table_id(), property(), value()) :: :ok
  defdelegate put(table, property, value), to: Updater

  @doc """
  Update many properties

  This is similar to calling `put/3` several times in a row, but atomically. It is
  also slightly more efficient when updating more than one property.
  """
  @spec put_many(table_id(), [{property(), value()}]) :: :ok
  defdelegate put_many(table, properties), to: Updater

  @doc """
  Delete the specified property
  """
  @spec delete(table_id(), property()) :: :ok
  defdelegate delete(table, property), to: Updater

  @doc """
  Delete all properties that match a pattern
  """
  @spec delete_matches(table_id(), pattern()) :: :ok
  defdelegate delete_matches(table, pattern), to: Updater

  @doc """
  If persistence is enabled for this property table, save the current state
  and copy a snapshot of it into the `/snapshots` sub-directory of the set
  data directory.
  """
  @spec snapshot(table_id()) :: {:ok, String.t()} | :noop
  defdelegate snapshot(table), to: Updater

  @doc """
  If persistence is enabled for this property table, save the current state
  to disk immediately.
  """
  @spec flush_to_disk(table_id()) :: :ok
  defdelegate flush_to_disk(table), to: Updater

  @doc """
  Returns a list of availiable snapshot IDs and full name tuples for
  a property table with persistence enable
  """
  @spec get_snapshots(table_id()) :: [{String.t(), String.t()}]
  defdelegate get_snapshots(table), to: Updater

  @doc """
  If persistence is enabled for this property table, restore the current state of the
  PropertyTable to that of a past named snapshot
  """
  @spec restore_snapshot(table_id(), String.t()) :: :ok | :noop
  defdelegate restore_snapshot(table, snapshot_name), to: Updater

  defp maybe_get_persistence_options(options) do
    if Keyword.has_key?(options, :persist_data_path) do
      table_name = Keyword.get(options, :name) |> Atom.to_string()

      # Set persistence options, and clean out any nil values
      # they will be filled with defaults in `PropertyTable.Persist`
      [
        data_directory: Keyword.get(options, :persist_data_path),
        table_name: table_name,
        interval: Keyword.get(options, :persist_interval),
        max_snapshots: Keyword.get(options, :persist_max_snapshots),
        compression: Keyword.get(options, :persist_compression)
      ]
      |> Enum.filter(fn {_, v} -> v != nil end)
    else
      # :persist_data_path must be set for any of the other options to be respected
      # no persistence will be configured
      nil
    end
  end
end
