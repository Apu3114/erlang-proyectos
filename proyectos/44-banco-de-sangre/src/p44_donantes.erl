%% Retiro inmediato de todo lo que provenga de un donante (prueba positiva tardía).
-module(p44_donantes).

-export([retirar/2]).

%% #{retiradas => N, ya_entregadas => [{IdUnidad, Receptor}]}
%% ya_entregadas: unidades que ya se transfundieron; hay que avisar a esos receptores.
retirar(Donante, Motivo) ->
  Pids = pg:get_members(p44_pg, {donante, Donante}),
  lists:foldl(fun(Pid, Acc) -> retirar_una(Pid, Motivo, Acc) end,
              #{retiradas => 0, ya_entregadas => []}, Pids).

retirar_una(Pid, Motivo, #{retiradas := N, ya_entregadas := Entregadas} = Acc) ->
  try p44_unidad:retirar(Pid, Motivo) of
    ok ->
      Acc#{retiradas := N + 1};
    {error, ya_asignada} ->
      {_, #{id := Id} = Datos} = p44_unidad:estado(Pid),
      Acc#{ya_entregadas := [{Id, maps:get(receptor, Datos, desconocido)} | Entregadas]}
  catch
    exit:_ -> Acc
  end.
