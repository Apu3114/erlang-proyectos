%% GET /metrics -- resumen para monitoreo: unidades por estado, por tipo/componente,
%% proximas a caducar, y total de unidades asignadas (como proxy de "solicitudes
%% atendidas": el sistema no distingue solicitudes urgentes de normales todavia,
%% asi que esto es una aproximacion, documentada aqui y en el README).
-module(p44_http_metricas_handler).

-export([init/2]).

-define(VENTANA_PROXIMAS_MS, 48 * 3600000).

init(Req0, State) ->
  Cuerpo = #{unidades_por_estado => conteo_estados(),
             existencias => existencias_planas(),
             proximas_a_caducar_48h => proximas_a_caducar(),
             unidades_asignadas_historico => total_asignadas()},
  Req = cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>},
                          p44_json:encode(Cuerpo), Req0),
  {ok, Req, State}.

conteo_estados() ->
  try
    lists:foldl(fun(Pid, Acc) ->
                    case p44_unidad:estado(Pid) of
                      {Estado, _} -> Acc#{Estado => maps:get(Estado, Acc, 0) + 1}
                    end
                end, #{}, pids_unidades())
  catch exit:_ -> #{}
  end.

pids_unidades() ->
  [Pid || {_, Pid, _, _} <- supervisor:which_children(p44_unidades_sup), is_pid(Pid)].

existencias_planas() ->
  try
    maps:from_list([{<<(atom_to_binary(T, utf8))/binary, $:, (atom_to_binary(C, utf8))/binary>>, N}
                     || {{T, C}, N} <- maps:to_list(p44_inventario:existencias())])
  catch exit:_ -> #{}
  end.

proximas_a_caducar() ->
  Ahora = erlang:system_time(millisecond),
  Limite = Ahora + ?VENTANA_PROXIMAS_MS,
  try
    length([x || Pid <- pids_unidades(),
                 {disponible, #{caduca_en := C}} <- [p44_unidad:estado(Pid)],
                 C =< Limite])
  catch exit:_ -> 0
  end.

%% Cuenta eventos 'asignada' en TODA la bitacora (no solo unidades vivas): recorre
%% las unidades conocidas por la bitacora, no por el supervisor, para no perder el
%% historial de unidades que ya no existen como proceso.
total_asignadas() ->
  try
    lists:sum([length([e || {_, #{estado := asignada}} <- p44_bitacora:historial(Id)])
                || #{id := Id} <- p44_bitacora:unidades()])
  catch exit:_ -> 0
  end.
