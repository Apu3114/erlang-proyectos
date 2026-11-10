%% Eventos recientes de trazabilidad, con filtro opcional ?unidad=ID.
-module(p44_http_bitacora_handler).
-export([init/2]).

init(Req0, State) ->
  Qs = cowboy_req:parse_qs(Req0),
  {Codigo, Cuerpo} = case proplists:get_value(<<"unidad">>, Qs) of
    undefined -> eventos();
    Bin -> case p44_http_unidades_handler:id(Bin) of
      {ok, Id} -> eventos(Id);
      error -> {400, #{error => unidad_invalida}}
    end
  end,
  {ok, p44_http_unidades_handler:responder(Codigo, Cuerpo, Req0), State}.

eventos() ->
  try
    Todos = lists:append([leer(maps:get(id, U)) || U <- p44_bitacora:unidades()]),
    {200, #{eventos => recientes(Todos)}}
  catch exit:_ -> {503, #{error => servicio_no_disponible}}
  end.

eventos(Id) ->
  try {200, #{eventos => recientes(leer(Id))}}
  catch exit:_ -> {503, #{error => servicio_no_disponible}}
  end.

leer(Id) ->
  [#{unidad => Id, fecha_ms => Fecha, evento => maps:get(evento, Evento),
     estado => maps:get(estado, Evento, undefined),
     descripcion => iolist_to_binary(io_lib:format("~tp", [Evento]))}
   || {Fecha, Evento} <- p44_bitacora:historial(Id)].

recientes(Todos) ->
  lists:sublist(lists:sort(fun(A, B) -> maps:get(fecha_ms, A) >= maps:get(fecha_ms, B) end,
                           Todos), 100).
