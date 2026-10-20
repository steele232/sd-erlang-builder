# Elixir smoke test on the SD runtime (bin/sd-build-elixir): run on node a
# with a second node's name as the argument.
#   elixir --sname a smoke.exs b@HOST
defmodule SdSmoke.Svc do
  use GenServer
  def init(s), do: {:ok, s}
  def handle_call(:ping, _from, s), do: {:reply, :pong, s}
end

defmodule SdSmoke do
  def eventually(f, n \\ 40) do
    case f.() do
      true -> true
      _ when n > 0 -> Process.sleep(250); eventually(f, n - 1)
      other -> other
    end
  end

  def check(label, ok) do
    IO.puts("elixir #{String.pad_trailing(label, 30)} #{if ok == true, do: "ok", else: inspect(ok)}")
    ok == true
  end
end

[b] = Enum.map(System.argv(), &String.to_atom/1)
via = {:via, :s_group, {:g, :svc}}

results = [
  # Free nodes: s_group:connect_node/1 dials only nodes sharing a group (RC1).
  SdSmoke.check("connect_node to a free node", :s_group.connect_node(b) == :ignored),
  SdSmoke.check("Node.connect", Node.connect(b)),
  SdSmoke.check("new_s_group", match?({:ok, :g, _}, :s_group.new_s_group(:g, [node(), b]))),
  SdSmoke.check("connect_node to a group-mate", :s_group.connect_node(b)),
  SdSmoke.check("own_s_groups on peer",
    SdSmoke.eventually(fn -> match?([{:g, _}], :erpc.call(b, :s_group, :own_s_groups, [])) end)),
  SdSmoke.check("GenServer via start", match?({:ok, _}, GenServer.start(SdSmoke.Svc, [], name: via))),
  SdSmoke.check("whereis from peer",
    SdSmoke.eventually(fn -> is_pid(:erpc.call(b, :s_group, :whereis_name, [{:g, :svc}])) end)),
  SdSmoke.check("GenServer.call from peer", :erpc.call(b, GenServer, :call, [via, :ping]) == :pong),
  SdSmoke.check("second start refused",
    match?({:error, {:already_started, _}}, GenServer.start(SdSmoke.Svc, [], name: via))),
  SdSmoke.check("global guarded on member",
    :global.register_name(:x, self()) == {:no, :the_node_is_not_free})
]

IO.puts("ELIXIR SMOKE: #{if Enum.all?(results), do: "pass", else: "FAIL"}")
System.halt(if Enum.all?(results), do: 0, else: 1)
