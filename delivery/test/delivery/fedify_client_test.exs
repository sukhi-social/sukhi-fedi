# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Delivery.FedifyClientTest do
  use ExUnit.Case, async: false

  alias SukhiDelivery.Delivery.FedifyClient

  defmodule StubService do
    @moduledoc false
    def call(topic, payload), do: {:ok, %{"topic" => topic, "payload" => payload}}
  end

  setup do
    old = Application.get_env(:sukhi_delivery, :fedify_service)
    Application.put_env(:sukhi_delivery, :fedify_service, StubService)

    on_exit(fn ->
      if old,
        do: Application.put_env(:sukhi_delivery, :fedify_service, old),
        else: Application.delete_env(:sukhi_delivery, :fedify_service)
    end)
  end

  test "with the service in this VM, translate calls it directly (no NATS)" do
    assert {:ok, %{"topic" => "fedify.translate.v1", "payload" => payload}} =
             FedifyClient.translate("note", %{"a" => 1})

    assert payload == %{object_type: "note", payload: %{"a" => 1}}
  end

  test "verify goes the same way, and ping needs no connection" do
    assert {:ok, %{"topic" => "fedify.verify.v1"}} = FedifyClient.verify(%{"x" => 1})
    assert :ok = FedifyClient.ping()
  end
end
