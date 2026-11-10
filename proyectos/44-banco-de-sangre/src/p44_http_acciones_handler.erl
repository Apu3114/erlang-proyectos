%% Acciones de una unidad: entregar (solo la propia reserva), liberar o retirar.
-module(p44_http_acciones_handler).
-export([init/2]).

init(Req0, State) ->
  {Codigo, Respuesta, Req1} = case cowboy_req:method(Req0) of
    <<"POST">> -> procesar(Req0);
    _ -> {405, #{error => metodo_no_permitido}, Req0}
  end,
  {ok, p44_http_unidades_handler:responder(Codigo, Respuesta, Req1), State}.

procesar(Req0) ->
  {ok, Bin, Req} = cowboy_req:read_body(Req0),
  case {p44_http_unidades_handler:id(cowboy_req:binding(id, Req)), p44_json:decode(Bin)} of
    {{ok, Id}, {ok, M}} when is_map(M) ->
      {Codigo, Respuesta} = accion(Id, M),
      {Codigo, Respuesta, Req};
    {error, _} -> {404, #{error => unidad_no_encontrada}, Req};
    _ -> {400, #{error => json_invalido}, Req}
  end.

accion(Id, #{<<"accion">> := <<"despachar">>, <<"solicitante">> := Sol,
             <<"receptor">> := Receptor})
  when is_binary(Sol), byte_size(Sol) > 0, byte_size(Sol) =< 100,
       is_binary(Receptor), byte_size(Receptor) > 0, byte_size(Receptor) =< 100 ->
  try
    case p44_unidad:estado(Id) of
      {reservada, #{solicitante := {http, Sol}}} ->
        case p44_unidad:asignar(Id, {http, Sol}, Receptor) of
          ok -> {200, #{ok => true, unidad => Id, estado => asignada}};
          {error, R} -> {409, #{error => R}}
        end;
      _ -> {409, #{error => reserva_no_coincide}}
    end
  catch exit:_ -> {503, #{error => servicio_no_disponible}}
  end;
accion(Id, #{<<"accion">> := <<"liberar">>}) ->
  try
    case p44_unidad:liberar(Id) of
      ok -> {200, #{ok => true, unidad => Id, estado => disponible}};
      {error, _} -> {409, #{error => unidad_no_reservada}}
    end
  catch exit:_ -> {503, #{error => servicio_no_disponible}}
  end;
accion(Id, #{<<"accion">> := <<"retirar">>, <<"motivo">> := Motivo})
  when is_binary(Motivo), byte_size(Motivo) > 0, byte_size(Motivo) =< 200 ->
  try
    case p44_unidad:retirar(Id, Motivo) of
      ok -> {200, #{ok => true, unidad => Id, estado => retirada}};
      {error, ya_asignada} -> {409, #{error => unidad_ya_entregada}}
    end
  catch exit:_ -> {503, #{error => servicio_no_disponible}}
  end;
accion(_, _) -> {400, #{error => accion_o_campos_invalidos}}.
