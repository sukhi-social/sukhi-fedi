defmodule Demo.W1 do
  use Oban.Worker, queue: :publish, max_attempts: 3
  def perform(_), do: :ok
end
