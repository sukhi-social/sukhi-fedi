defmodule Demo.W0 do
  use Oban.Worker, queue: :monitor, max_attempts: 3
  def perform(_), do: :ok
end
