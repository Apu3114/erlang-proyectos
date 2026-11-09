%% POST /api/solicitudes
%% Body: {"receptor": "a_pos", "componente": "globulos_rojos",
%%        "solicitante": "cirugia_1" (opcional), "ttl_ms": 3600000 (opcional)}
%% 200 {"ok": true, "id": N, "tipo": "...", "exacto": bool}
%% 400 {"ok": false, "error": "..."}  -- cuerpo invalido o campo invalido
%% 404 {"ok": false, "error": "sin_existencias"}
-module(p44_http_solicitudes_handler).

-export([init/2]).

-define(TTL_DEFAULT, 3600000).

init(Req0, State) ->
  {ok, CuerpoBin, Req1} = cowboy_req:read_body(Req0),
  Req = responder(procesar(CuerpoBin), Req1),
  {ok, Req, State}.

procesar(CuerpoBin) ->
  case p44_json:decode(CuerpoBin) of
    {ok, Mapa} when is_map(Mapa) -> validar(Mapa);
    {ok, _} -> {400, error_json(cuerpo_debe_ser_un_objeto)};
    {error, _} -> {400, error_json(json_invalido)}
  end.

validar(Mapa) ->
  case {atomo_valido(maps:get(<<"receptor">>, Mapa, undefined), p44_compatibilidad:tipos()),
        atomo_valido(maps:get(<<"componente">>, Mapa, undefined), p44_compatibilidad:componentes())} of
    {{error, _}, _} -> {400, error_json(receptor_invalido)};
    {_, {error, _}} -> {400, error_json(componente_invalido)};
    {{ok, Receptor}, {ok, Componente}} ->
      Solicitante = solicitante(Mapa),
      Ttl = ttl(Mapa),
      atender(Receptor, Componente, Solicitante, Ttl)
  end.

atender(Receptor, Componente, Solicitante, Ttl) ->
  try p44_inventario:solicitar(Receptor, Componente, Solicitante, Ttl) of
    {ok, #{id := Id, tipo := Tipo, exacto := Exacto}} ->
      {200, #{ok => true, id => Id, tipo => Tipo, exacto => Exacto}};
    {error, sin_existencias} ->
      {404, error_json(sin_existencias)}
  catch
    exit:_ -> {503, error_json(inventario_no_disponible)}
  end.

%% Solo acepta un atomo de la lista blanca Permitidos: nunca binary_to_atom libre
%% sobre datos externos (agotaria la tabla de atomos con suficientes solicitudes).
atomo_valido(Bin, Permitidos) when is_binary(Bin) ->
  busca(Bin, Permitidos);
atomo_valido(_, _) -> {error, invalido}.

busca(_Bin, []) -> {error, invalido};
busca(Bin, [A | Resto]) ->
  case atom_to_binary(A, utf8) =:= Bin of
    true -> {ok, A};
    false -> busca(Bin, Resto)
  end.

solicitante(Mapa) ->
  case maps:get(<<"solicitante">>, Mapa, undefined) of
    undefined -> http;
    Bin when is_binary(Bin) -> {http, Bin};
    _ -> http
  end.

ttl(Mapa) ->
  case maps:get(<<"ttl_ms">>, Mapa, ?TTL_DEFAULT) of
    N when is_integer(N), N > 0 -> N;
    _ -> ?TTL_DEFAULT
  end.

error_json(Razon) -> #{ok => false, error => Razon}.

responder({Codigo, Cuerpo}, Req) ->
  cowboy_req:reply(Codigo, #{<<"content-type">> => <<"application/json">>},
                    p44_json:encode(Cuerpo), Req).
