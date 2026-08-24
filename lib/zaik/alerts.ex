defmodule Zaik.Alerts do
  @moduledoc """
  Public alert-rule facade.
  """

  @weekday_numbers %{
    "monday" => 1,
    "mon" => 1,
    "tuesday" => 2,
    "tue" => 2,
    "wednesday" => 3,
    "wed" => 3,
    "thursday" => 4,
    "thu" => 4,
    "friday" => 5,
    "fri" => 5,
    "saturday" => 6,
    "sat" => 6,
    "sunday" => 7,
    "sun" => 7
  }

  def create_presence_alert(attrs) when is_map(attrs) do
    Zaik.Alerts.RuleStore.create(Map.put(attrs, :type, :presence_detected))
  end

  def list(status \\ :active), do: Zaik.Alerts.RuleStore.list(status)
  def get(id), do: Zaik.Alerts.RuleStore.get(id)
  def cancel(id), do: Zaik.Alerts.RuleStore.cancel(id)

  @doc """
  Parse a limited deterministic `until` expression into a UTC DateTime.

  Supported examples:

  - `saturday` / `sat`
  - `tomorrow`
  - `today`
  - `2026-08-30`
  - `2026-08-30 09:00`
  - ISO8601 DateTime strings accepted by `DateTime.from_iso8601/1`
  """
  def parse_until(text, now \\ DateTime.utc_now()) when is_binary(text) do
    text = text |> String.trim() |> String.downcase()

    cond do
      text == "" ->
        {:error, :empty_until}

      text in ["today", "tonight"] ->
        {:ok, end_of_local_day(local_date(now), now)}

      text == "tomorrow" ->
        {:ok, now |> local_date() |> Date.add(1) |> end_of_local_day(now)}

      Map.has_key?(@weekday_numbers, text) ->
        {:ok, text |> next_weekday_date(now) |> end_of_local_day(now)}

      match = Regex.run(~r/^(\d{4}-\d{2}-\d{2})$/, text, capture: :all_but_first) ->
        with {:ok, date} <- match |> hd() |> Date.from_iso8601() do
          {:ok, end_of_local_day(date, now)}
        end

      match =
          Regex.run(~r/^(\d{4}-\d{2}-\d{2})[ t](\d{1,2}):(\d{2})$/, text, capture: :all_but_first) ->
        [date_text, hour_text, minute_text] = match

        with {:ok, date} <- Date.from_iso8601(date_text),
             {hour, ""} <- Integer.parse(hour_text),
             {minute, ""} <- Integer.parse(minute_text),
             true <- hour in 0..23 and minute in 0..59 do
          {:ok, local_datetime_to_utc(date, {hour, minute, 0}, now)}
        else
          _ -> {:error, :invalid_until}
        end

      true ->
        case DateTime.from_iso8601(text) do
          {:ok, datetime, _offset} -> {:ok, datetime}
          _ -> {:error, :invalid_until}
        end
    end
  end

  defp next_weekday_date(day_text, now) do
    today = local_date(now)
    today_num = Date.day_of_week(today)
    target_num = Map.fetch!(@weekday_numbers, day_text)
    days = rem(target_num - today_num + 7, 7)
    Date.add(today, if(days == 0, do: 7, else: days))
  end

  defp local_date(_now) do
    {{year, month, day}, _time} = :calendar.local_time()
    Date.new!(year, month, day)
  end

  defp end_of_local_day(date, now), do: local_datetime_to_utc(date, {23, 59, 59}, now)

  defp local_datetime_to_utc(date, {hour, minute, second}, now) do
    local = {{date.year, date.month, date.day}, {hour, minute, second}}

    utc_seconds =
      :calendar.datetime_to_gregorian_seconds(DateTime.to_naive(now) |> NaiveDateTime.to_erl())

    local_now_seconds = :calendar.datetime_to_gregorian_seconds(:calendar.local_time())
    offset_seconds = local_now_seconds - utc_seconds

    local
    |> :calendar.datetime_to_gregorian_seconds()
    |> Kernel.-(offset_seconds)
    |> :calendar.gregorian_seconds_to_datetime()
    |> NaiveDateTime.from_erl!()
    |> DateTime.from_naive!("Etc/UTC")
  end
end
