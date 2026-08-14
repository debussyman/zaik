defmodule Zaik.CommandProcessor do
  @moduledoc """
  Safe text command processor for local and messaging-based control surfaces.
  """

  @brief_await_ms 2_000

  def process(text, context \\ %{})

  def process(text, context) when is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" ->
        help()

      command?(text, "help") ->
        help()

      command?(text, "health") ->
        format_health()

      command?(text, "snapshot") ->
        inspect(Zaik.Observability.snapshot(), pretty: true, limit: 50)

      command?(text, "queue") ->
        format_queue()

      command?(text, "tasks") ->
        format_tasks(nil)

      command?(text, "sessions") ->
        format_sessions()

      command?(text, "home") ->
        format_home()

      command?(text, "home status") ->
        format_home()

      command?(text, "home devices") ->
        format_home_devices()

      command?(text, "home sensors") ->
        format_home_sensors()

      command?(text, "home trends") ->
        format_home_trends()

      command?(text, "presence") ->
        format_presence()

      command?(text, "system") ->
        submit_system(context)

      command?(text, "watchdog") ->
        format_watchdog_state()

      command?(text, "watchdog scan") ->
        format_watchdog_scan()

      command?(text, "ask") ->
        submit_llm_prompt("", context)

      command?(text, "submit llm") ->
        submit_llm_prompt("", context)

      String.starts_with?(downcase(text), "ask ") ->
        text |> rest_after("ask") |> submit_llm_prompt(context)

      String.starts_with?(downcase(text), "submit llm ") ->
        text |> rest_after("submit llm") |> submit_llm_prompt(context)

      String.starts_with?(downcase(text), "tasks ") ->
        text |> rest_after("tasks") |> format_tasks()

      String.starts_with?(downcase(text), "task ") ->
        text |> rest_after("task") |> format_task()

      String.starts_with?(downcase(text), "sensor ") and
          String.ends_with?(downcase(text), " trend") ->
        text |> rest_after("sensor") |> remove_suffix("trend") |> format_sensor_trend()

      String.starts_with?(downcase(text), "home sensor ") and
          String.ends_with?(downcase(text), " trend") ->
        text |> rest_after("home sensor") |> remove_suffix("trend") |> format_sensor_trend()

      String.starts_with?(downcase(text), "sensor ") ->
        text |> rest_after("sensor") |> format_sensor()

      String.starts_with?(downcase(text), "home sensor ") ->
        text |> rest_after("home sensor") |> format_sensor()

      String.starts_with?(downcase(text), "submit echo ") ->
        text |> rest_after("submit echo") |> submit_echo(context)

      String.starts_with?(downcase(text), "echo ") ->
        text |> rest_after("echo") |> submit_echo(context)

      command?(text, "submit system") ->
        submit_system(context)

      true ->
        "Unknown command.\n\n" <> help()
    end
  end

  def process(_text, _context), do: help()

  def help do
    """
    Zaik commands:
    help
    health
    snapshot
    queue
    tasks
    tasks queued|running|failed
    task <task_id>
    sessions
    home
    home devices
    home sensors
    home trends
    presence
    sensor <device name>
    sensor <device name> trend
    watchdog
    watchdog scan
    ask <prompt>
    submit llm <prompt>
    submit echo <message>
    echo <message>
    system
    """
    |> String.trim()
  end

  defp format_health do
    snapshot = Zaik.Observability.snapshot()
    tasks = snapshot.tasks

    """
    Zaik is #{snapshot.status}.
    Queue: #{snapshot.queue.size}
    Running: #{tasks.running}
    Succeeded: #{tasks.succeeded}
    Failed: #{tasks.failed}
    Timed out: #{tasks.timed_out}
    """
    |> String.trim()
  end

  defp format_queue do
    queue = Zaik.Observability.queue_summary()
    "Queue: #{queue.size}"
  end

  defp format_home do
    devices = Zaik.home_devices()
    presence_devices = Zaik.presence_devices()
    mqtt = Zaik.mqtt_status()

    present = Enum.count(presence_devices, &(Map.get(&1.payload, "presence") == true))

    """
    Home
    MQTT: #{if mqtt.connected?, do: "connected", else: "disconnected"}
    Devices: #{length(devices)}
    Presence sensors: #{length(presence_devices)}
    Present: #{present}
    """
    |> String.trim()
  rescue
    _ -> "Home integration is not available."
  catch
    :exit, _ -> "Home integration is not available."
  end

  defp format_home_devices do
    case Zaik.home_devices() do
      [] ->
        "No home devices seen yet."

      devices ->
        (["Home devices"] ++ Enum.map(devices, &format_device_summary/1)) |> Enum.join("\n")
    end
  end

  defp format_home_sensors do
    case Zaik.home_devices() do
      [] ->
        "No home sensors seen yet."

      devices ->
        (["Home sensors"] ++ Enum.map(devices, &format_device_sensor_line/1)) |> Enum.join("\n")
    end
  end

  defp format_presence do
    case Zaik.presence_devices() do
      [] ->
        "No presence sensors seen yet."

      devices ->
        (["Presence"] ++ Enum.map(devices, &format_presence_line/1)) |> Enum.join("\n")
    end
  end

  defp format_home_trends do
    case Zaik.home_devices() do
      [] ->
        "No home devices seen yet."

      devices ->
        trend_lines =
          devices
          |> Enum.map(&format_trend_for_device/1)
          |> Enum.reject(&is_nil/1)

        case trend_lines do
          [] -> "I need more sensor history before I can describe home trends."
          lines -> (["Home trends"] ++ lines) |> Enum.join("\n")
        end
    end
  end

  defp format_sensor_trend(query) do
    query = String.trim(query)

    if query == "" do
      "Usage: sensor <device name> trend"
    else
      case Zaik.home_device(query) do
        {:ok, device} ->
          format_trend_for_device(device) ||
            "I need more history for #{room_label(device.friendly_name)} before I can describe a trend."

        {:error, :not_found} ->
          "Sensor not found: #{query}"

        {:error, {:ambiguous, names}} ->
          "Sensor name is ambiguous: #{query}\nMatches: #{Enum.join(names, ", ")}"
      end
    end
  end

  defp format_sensor(query) do
    query = String.trim(query)

    if query == "" do
      "Usage: sensor <device name>"
    else
      case Zaik.home_device(query) do
        {:ok, device} ->
          format_device_detail(device)

        {:error, :not_found} ->
          "Sensor not found: #{query}"

        {:error, {:ambiguous, names}} ->
          "Sensor name is ambiguous: #{query}\nMatches: #{Enum.join(names, ", ")}"
      end
    end
  end

  defp format_tasks(nil) do
    tasks = Zaik.Observability.task_summary()

    """
    Tasks
    Queued: #{tasks.queued}
    Assigned: #{tasks.assigned}
    Running: #{tasks.running}
    Succeeded: #{tasks.succeeded}
    Failed: #{tasks.failed}
    Cancelled: #{tasks.cancelled}
    Timed out: #{tasks.timed_out}
    """
    |> String.trim()
  end

  defp format_tasks(status_text) when is_binary(status_text) do
    case parse_status(status_text) do
      {:ok, status} ->
        tasks = Zaik.list_tasks(status: status)

        case tasks do
          [] ->
            "No #{status} tasks."

          tasks ->
            lines =
              tasks
              |> Enum.take(-10)
              |> Enum.map(&format_task_line/1)

            (["#{String.capitalize(to_string(status))} tasks"] ++ lines) |> Enum.join("\n")
        end

      :error ->
        "Unknown task status: #{status_text}"
    end
  end

  defp format_task(task_id) do
    task_id = String.trim(task_id)

    case Zaik.get_task(task_id) do
      {:ok, task} ->
        """
        Task #{task.id}
        Type: #{task.type}
        Status: #{task.status}
        Attempts: #{task.attempts}/#{task.max_retries + 1}
        Submitted: #{format_time(task.submitted_at)}
        Started: #{format_time(task.started_at)}
        Completed: #{format_time(task.completed_at)}
        Result: #{format_value(task.result)}
        Error: #{format_value(task.error)}
        """
        |> String.trim()

      {:error, :not_found} ->
        "Task not found: #{task_id}"
    end
  end

  defp format_sessions do
    summary = Zaik.Observability.session_summary(limit: 10)

    case summary.recent do
      [] ->
        "No sessions."

      sessions ->
        lines =
          Enum.map(sessions, fn session ->
            "#{session.id} #{session.scope} #{session.cwd} updated=#{format_time(session.updated_at)}"
          end)

        (["Recent sessions"] ++ lines) |> Enum.join("\n")
    end
  end

  defp format_watchdog_state do
    case Zaik.watchdog_state() do
      %{last_scan_at: nil, last_summary: summary} ->
        "Watchdog has not scanned yet.\nLast summary: #{format_value(summary)}"

      %{last_scan_at: scanned_at, last_summary: summary} ->
        "Watchdog last scanned at #{format_time(scanned_at)}.\n" <>
          format_watchdog_summary(summary)
    end
  rescue
    _ -> "Watchdog is not available."
  catch
    :exit, _ -> "Watchdog is not available."
  end

  defp format_watchdog_scan do
    Zaik.watchdog_scan()
    |> format_watchdog_summary("Watchdog scan complete.")
  rescue
    error -> "Watchdog scan failed: #{Exception.message(error)}"
  catch
    :exit, reason -> "Watchdog scan failed: #{inspect(reason)}"
  end

  defp format_watchdog_summary(summary, header \\ "Watchdog summary.") when is_map(summary) do
    """
    #{header}
    Requeued missing queued: #{Map.get(summary, :requeued_missing_queued_tasks, 0)}
    Removed terminal queue entries: #{Map.get(summary, :removed_terminal_queue_entries, 0)}
    Removed missing queue entries: #{Map.get(summary, :removed_missing_queue_entries, 0)}
    Requeued stale assigned: #{Map.get(summary, :requeued_stale_assigned_tasks, 0)}
    Failed stale assigned: #{Map.get(summary, :failed_stale_assigned_tasks, 0)}
    Requeued orphaned running: #{Map.get(summary, :requeued_orphaned_running_tasks, 0)}
    Failed orphaned running: #{Map.get(summary, :failed_orphaned_running_tasks, 0)}
    Requeued stale running: #{Map.get(summary, :requeued_stale_running_tasks, 0)}
    Failed stale running: #{Map.get(summary, :failed_stale_running_tasks, 0)}
    Terminated terminal agents: #{Map.get(summary, :terminated_terminal_task_agents, 0)}
    """
    |> String.trim()
  end

  defp submit_echo(message, context) do
    message = String.trim(message)

    if message == "" do
      "Usage: submit echo <message>"
    else
      opts = task_opts(context)

      case Zaik.submit_task(:echo, %{message: message}, opts) do
        {:ok, task_id} ->
          case Zaik.await_task(task_id, @brief_await_ms) do
            {:ok, result} ->
              "Submitted echo task #{task_id}.\nResult: #{format_echo_result(result)}"

            {:error, :timeout} ->
              "Submitted echo task #{task_id}.\nTask is still running."

            {:error, reason} ->
              "Submitted echo task #{task_id}.\nTask failed: #{format_value(reason)}"
          end

        {:error, reason} ->
          "Failed to submit echo task: #{format_value(reason)}"
      end
    end
  end

  defp submit_llm_prompt(prompt, context) do
    prompt = String.trim(prompt)

    if prompt == "" do
      "Usage: ask <prompt>"
    else
      opts =
        context
        |> task_opts()
        |> Keyword.put_new(:timeout_ms, Zaik.LLM.OllamaClient.config().timeout_ms)

      payload = %{
        prompt: prompt,
        model: Zaik.LLM.OllamaClient.config().default_model,
        num_predict: Zaik.LLM.OllamaClient.config().num_predict,
        num_ctx: Zaik.LLM.OllamaClient.config().num_ctx,
        temperature: Zaik.LLM.OllamaClient.config().temperature
      }

      case Zaik.submit_task(:llm_prompt, payload, opts) do
        {:ok, task_id} ->
          case Zaik.await_task(task_id, Zaik.LLM.OllamaClient.config().timeout_ms + 5_000) do
            {:ok, result} ->
              "LLM task #{task_id}.\n" <> format_llm_result(result)

            {:error, :timeout} ->
              "LLM task #{task_id} is still running."

            {:error, reason} ->
              "LLM task #{task_id} failed: #{format_value(reason)}"
          end

        {:error, reason} ->
          "Failed to submit LLM task: #{format_value(reason)}"
      end
    end
  end

  defp submit_system(context) do
    opts = task_opts(context)

    case Zaik.submit_task(:system_status, %{detail: :basic}, opts) do
      {:ok, task_id} ->
        case Zaik.await_task(task_id, @brief_await_ms) do
          {:ok, result} ->
            "System status task #{task_id}.\n" <> format_system_result(result)

          {:error, :timeout} ->
            "System status task #{task_id} is still running."

          {:error, reason} ->
            "System status task #{task_id} failed: #{format_value(reason)}"
        end

      {:error, reason} ->
        "Failed to submit system status task: #{format_value(reason)}"
    end
  end

  defp task_opts(%{session_id: session_id}) when is_binary(session_id),
    do: [session_id: session_id]

  defp task_opts(_context), do: []

  defp parse_status(status_text) do
    case status_text |> String.trim() |> String.downcase() do
      "queued" -> {:ok, :queued}
      "assigned" -> {:ok, :assigned}
      "running" -> {:ok, :running}
      "succeeded" -> {:ok, :succeeded}
      "failed" -> {:ok, :failed}
      "cancelled" -> {:ok, :cancelled}
      "timed_out" -> {:ok, :timed_out}
      "timed out" -> {:ok, :timed_out}
      _ -> :error
    end
  end

  defp format_task_line(task) do
    "#{task.id} #{task.type} status=#{task.status} submitted=#{format_time(task.submitted_at)}"
  end

  defp format_echo_result(%{message: message}), do: message
  defp format_echo_result(%{"message" => message}), do: message
  defp format_echo_result(result), do: format_value(result)

  defp format_system_result(result) when is_map(result) do
    """
    Node: #{Map.get(result, :node) || Map.get(result, "node")}
    Uptime ms: #{Map.get(result, :uptime_ms) || Map.get(result, "uptime_ms")}
    Processes: #{Map.get(result, :process_count) || Map.get(result, "process_count")}
    Schedulers: #{Map.get(result, :schedulers_online) || Map.get(result, "schedulers_online")}
    """
    |> String.trim()
  end

  defp format_system_result(result), do: format_value(result)

  defp format_llm_result(%{response: response}) when is_binary(response),
    do: String.trim(response)

  defp format_llm_result(%{"response" => response}) when is_binary(response),
    do: String.trim(response)

  defp format_llm_result(result), do: format_value(result)

  defp format_device_summary(device) do
    "- #{device.friendly_name}: #{device_short_state(device)} updated=#{format_time(device.updated_at)}"
  end

  defp format_device_sensor_line(device) do
    "- #{device.friendly_name}: #{sensor_values(device.payload)}"
  end

  defp format_presence_line(device) do
    presence = Map.get(device.payload, "presence")
    distance = Map.get(device.payload, "target_distance")

    suffix =
      if is_nil(distance) do
        ""
      else
        " distance=#{distance}"
      end

    "- #{device.friendly_name}: presence=#{presence}#{suffix} updated=#{format_time(device.updated_at)}"
  end

  defp format_device_detail(device) do
    metadata_keys = [
      "description",
      "manufacturer",
      "model_id",
      "ieee_address",
      "power_source",
      "source",
      "topic"
    ]

    metadata_lines =
      metadata_keys
      |> Enum.filter(&(Map.get(device.metadata, &1) not in [nil, ""]))
      |> Enum.map(fn key -> "#{key}: #{format_value(Map.fetch!(device.metadata, key))}" end)

    [
      summary_sentence(device),
      measurement_sentence(device.payload),
      presence_sentence(device.payload),
      battery_sentence(device.payload),
      settings_sentence(device.payload),
      "Sensor: #{device.friendly_name}.",
      "Updated: #{format_time(device.updated_at)}.",
      metadata_section(metadata_lines)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp metadata_section([]), do: nil
  defp metadata_section(lines), do: "Metadata\n" <> Enum.join(lines, "\n")

  defp format_trend_for_device(device) do
    case Zaik.home_trend(device.friendly_name) do
      {:ok, trend} -> format_trend(device, trend)
      {:error, :insufficient_data} -> nil
      {:error, _reason} -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp format_trend(device, trend) do
    room = room_label(device.friendly_name)
    temperature = trend.temperature
    humidity = trend.humidity
    illuminance = trend.illuminance

    [
      trend_summary_sentence(room, temperature, humidity, illuminance),
      temperature_trend_sentence(temperature, trend.window_seconds),
      humidity_trend_sentence(humidity),
      illuminance_trend_sentence(illuminance),
      "Based on #{trend.readings_count} readings over #{format_window(trend.window_seconds)}."
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp trend_summary_sentence(room, %{trend: :falling}, _humidity, _illuminance),
    do: "#{room} is cooling."

  defp trend_summary_sentence(room, %{trend: :rising}, _humidity, _illuminance),
    do: "#{room} is warming."

  defp trend_summary_sentence(room, _temperature, %{trend: :rising}, _illuminance),
    do: "#{room} is getting more humid."

  defp trend_summary_sentence(room, _temperature, %{trend: :falling}, _illuminance),
    do: "#{room} is getting drier."

  defp trend_summary_sentence(room, _temperature, _humidity, %{trend: :rising}),
    do: "#{room} is getting brighter."

  defp trend_summary_sentence(room, _temperature, _humidity, %{trend: :falling}),
    do: "#{room} is getting darker."

  defp trend_summary_sentence(room, _temperature, _humidity, _illuminance),
    do: "#{room} is steady."

  defp temperature_trend_sentence(nil, _window_seconds), do: nil

  defp temperature_trend_sentence(%{current: current, delta: delta, trend: trend}, window_seconds) do
    direction = delta_phrase(delta, "up", "down", &format_fahrenheit/1)

    case trend do
      :steady ->
        "Temperature is steady at #{format_fahrenheit(current)}."

      _ ->
        "It is now #{format_fahrenheit(current)}, #{direction} over #{format_window(window_seconds)}."
    end
  end

  defp humidity_trend_sentence(nil), do: nil

  defp humidity_trend_sentence(%{current: current, delta: delta, trend: trend}) do
    case trend do
      :steady ->
        "Humidity is steady at #{format_percent(current)}."

      :rising ->
        "Humidity is rising to #{format_percent(current)}, up #{format_percent(abs(delta))}."

      :falling ->
        "Humidity is falling to #{format_percent(current)}, down #{format_percent(abs(delta))}."
    end
  end

  defp illuminance_trend_sentence(nil), do: nil

  defp illuminance_trend_sentence(%{current: current, delta: delta, trend: trend}) do
    case trend do
      :steady ->
        "Illuminance is steady at #{format_lux(current)}."

      :rising ->
        "The room is getting brighter at #{format_lux(current)}, up #{format_lux(abs(delta))}."

      :falling ->
        "The room is getting darker at #{format_lux(current)}, down #{format_lux(abs(delta))}."
    end
  end

  defp delta_phrase(delta, rising_word, _falling_word, formatter) when delta >= 0,
    do: "#{rising_word} #{formatter.(abs(delta))}"

  defp delta_phrase(delta, _rising_word, falling_word, formatter),
    do: "#{falling_word} #{formatter.(abs(delta))}"

  defp format_window(1), do: "1 second"
  defp format_window(seconds) when seconds < 120, do: "#{seconds} seconds"
  defp format_window(seconds) when seconds < 3600, do: plural(round(seconds / 60), "minute")
  defp format_window(seconds), do: plural(Float.round(seconds / 3600, 1), "hour")

  defp plural(1, unit), do: "1 #{unit}"
  defp plural(1.0, unit), do: "1 #{unit}"
  defp plural(value, unit), do: "#{format_number(value)} #{unit}s"

  defp summary_sentence(device) do
    room = room_label(device.friendly_name)
    light = device.payload |> number_field("illuminance") |> light_description()
    temperature = device.payload |> fahrenheit_field("temperature") |> temperature_description()

    descriptors = Enum.reject([light, temperature], &is_nil/1)

    case descriptors do
      [] -> "#{room} has recent sensor readings."
      [descriptor] -> "#{room} is #{descriptor}."
      [first, second | _] -> "#{room} is #{first} and #{second}."
    end
  end

  defp measurement_sentence(payload) do
    measurements =
      [
        format_measurement(
          fahrenheit_field(payload, "temperature"),
          "temperature",
          &format_fahrenheit/1
        ),
        format_measurement(number_field(payload, "humidity"), "humidity", &format_percent/1),
        format_measurement(number_field(payload, "illuminance"), "illuminance", &format_lux/1)
      ]
      |> Enum.reject(&is_nil/1)

    case measurements do
      [] -> nil
      [single] -> "The #{single}."
      [first, second] -> "The #{first} and #{second}."
      [first, second, third] -> "The #{first}, #{second}, and #{third}."
    end
  end

  defp presence_sentence(payload) do
    presence = Map.get(payload, "presence")
    pir = Map.get(payload, "pir_detection")
    distance = number_field(payload, "target_distance")

    cond do
      is_boolean(presence) and is_boolean(pir) and not is_nil(distance) ->
        "Presence is #{presence_phrase(presence)}, PIR motion is #{boolean_phrase(pir)}, and target distance is #{format_number(distance)}."

      is_boolean(presence) ->
        "Presence is #{presence_phrase(presence)}."

      true ->
        nil
    end
  end

  defp battery_sentence(payload) do
    battery = number_field(payload, "battery")
    voltage = number_field(payload, "voltage")

    cond do
      battery && voltage ->
        "Battery is #{format_number(battery)}% at #{format_number(voltage)} mV."

      battery ->
        "Battery is #{format_number(battery)}%."

      voltage ->
        "Battery voltage is #{format_number(voltage)} mV."

      true ->
        nil
    end
  end

  defp settings_sentence(payload) do
    sensitivity = Map.get(payload, "motion_sensitivity")
    delay = number_field(payload, "absence_delay_timer")
    detection = Map.get(payload, "presence_detection_options")

    parts =
      [
        if(sensitivity, do: "motion sensitivity is #{sensitivity}"),
        if(delay, do: "absence delay is #{format_number(delay)} seconds"),
        if(detection, do: "presence detection is #{detection}")
      ]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> nil
      [single] -> "Configuration: #{single}."
      _ -> "Configuration: #{Enum.join(parts, ", ")}."
    end
  end

  defp device_short_state(device) do
    payload = device.payload

    [summary_sentence(device), measurement_sentence(payload)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp sensor_values(payload) do
    [
      field(payload, "presence", &"presence=#{&1}"),
      field_value(fahrenheit_field(payload, "temperature"), "temp", &format_fahrenheit/1),
      field(payload, "humidity", &"humidity=#{format_number(&1)}%"),
      field(payload, "illuminance", &"illuminance=#{format_number(&1)} lux"),
      field(payload, "battery", &"battery=#{format_number(&1)}%")
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "state seen"
      parts -> Enum.join(parts, " ")
    end
  end

  defp field(payload, key, formatter) do
    case Map.fetch(payload, key) do
      {:ok, value} -> formatter.(value)
      :error -> nil
    end
  end

  defp field_value(nil, _label, _formatter), do: nil
  defp field_value(value, label, formatter), do: "#{label}=#{formatter.(value)}"

  defp format_measurement(nil, _name, _formatter), do: nil
  defp format_measurement(value, name, formatter), do: "#{name} is #{formatter.(value)}"

  defp fahrenheit_field(payload, key) do
    case number_field(payload, key) do
      nil -> nil
      celsius -> celsius * 9 / 5 + 32
    end
  end

  defp number_field(payload, key) do
    case Map.fetch(payload, key) do
      {:ok, value} -> parse_number(value)
      :error -> nil
    end
  end

  defp parse_number(value) when is_integer(value) or is_float(value), do: value

  defp parse_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp parse_number(_value), do: nil

  defp room_label(friendly_name) do
    base =
      friendly_name
      |> String.replace(~r/[_-]+/, " ")
      |> String.replace(~r/\b(fp300|presence sensor|multi sensor|sensor|presence)\b/i, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> titleize()

    downcased = String.downcase(base)

    cond do
      base == "" ->
        "This room"

      String.ends_with?(downcased, "'s room") ->
        base |> String.replace_suffix(" Room", " room")

      String.ends_with?(downcased, " room") ->
        "The " <> String.downcase(base)

      String.match?(base, ~r/^[A-Z][a-z]+$/) ->
        "#{possessive(base)} room"

      true ->
        "The #{String.downcase(base)}"
    end
  end

  defp titleize(value) do
    value
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map_join(" ", fn word -> String.capitalize(String.downcase(word)) end)
  end

  defp possessive(value) do
    if String.ends_with?(String.downcase(value), "s"), do: value <> "'", else: value <> "'s"
  end

  defp light_description(nil), do: nil
  defp light_description(lux) when lux >= 300, do: "bright"
  defp light_description(lux) when lux >= 100, do: "moderately bright"
  defp light_description(lux) when lux >= 30, do: "dim"
  defp light_description(_lux), do: "dark"

  defp temperature_description(nil), do: nil
  defp temperature_description(fahrenheit) when fahrenheit >= 78, do: "hot"
  defp temperature_description(fahrenheit) when fahrenheit >= 72, do: "warm"
  defp temperature_description(fahrenheit) when fahrenheit >= 66, do: "comfortable"
  defp temperature_description(fahrenheit) when fahrenheit >= 60, do: "cool"
  defp temperature_description(_fahrenheit), do: "cold"

  defp presence_phrase(true), do: "detected"
  defp presence_phrase(false), do: "not detected"

  defp boolean_phrase(true), do: "active"
  defp boolean_phrase(false), do: "inactive"

  defp format_fahrenheit(value), do: "#{format_number(value)}°F"
  defp format_percent(value), do: "#{format_number(value)}%"
  defp format_lux(value), do: "#{format_number(value)} lux"

  defp format_number(value) when is_integer(value), do: Integer.to_string(value)

  defp format_number(value) when is_float(value) do
    rounded = Float.round(value, 1)

    if rounded == trunc(rounded) do
      Integer.to_string(trunc(rounded))
    else
      :erlang.float_to_binary(rounded, decimals: 1)
    end
  end

  defp format_number(value), do: to_string(value)

  defp format_value(nil), do: "-"
  defp format_value(value) when is_binary(value), do: value

  defp format_value(value) when is_map(value) or is_list(value),
    do: inspect(value, limit: 5, printable_limit: 200)

  defp format_value(value), do: inspect(value, limit: 20)

  defp format_time(nil), do: "-"
  defp format_time(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp format_time(time), do: to_string(time)

  defp command?(text, command), do: downcase(text) == command
  defp downcase(text), do: text |> String.trim() |> String.downcase()

  defp rest_after(text, prefix) do
    text
    |> String.trim()
    |> String.slice(String.length(prefix)..-1//1)
    |> String.trim()
  end

  defp remove_suffix(text, suffix) do
    text
    |> String.trim()
    |> String.replace(~r/\s+#{Regex.escape(suffix)}\s*$/i, "")
    |> String.trim()
  end
end
