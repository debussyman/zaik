defmodule Zaik.Time do
  @moduledoc """
  Injectable time and timer facade.

  Production callers use the system clock by passing `nil`. Deterministic
  environments pass `{module, server}` where the module implements `now/1`,
  `monotonic_ms/1`, and `send_after/4`.
  """

  @type provider :: nil | {module(), GenServer.server()}

  def now(nil), do: DateTime.utc_now()
  def now({module, server}), do: apply(module, :now, [server])

  def monotonic_ms(nil), do: System.monotonic_time(:millisecond)
  def monotonic_ms({module, server}), do: apply(module, :monotonic_ms, [server])

  def send_after(nil, target, message, delay_ms),
    do: Process.send_after(target, message, delay_ms)

  def send_after({module, server}, target, message, delay_ms),
    do: apply(module, :send_after, [server, target, message, delay_ms])
end
