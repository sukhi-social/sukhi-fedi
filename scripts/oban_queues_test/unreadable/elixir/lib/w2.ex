defmodule Demo.W2 do
  use Oban.Worker, queue: :preview, max_attempts: 3
  def perform(_), do: :ok
end
