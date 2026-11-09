%% GET /api/inventario -> existencias por tipo y componente.
-module(p44_http_inventario_handler).

-export([init/2]).

init(Req0, State) ->
  Existencias = try p44_inventario:existencias() catch exit:_ -> #{} end,
  %% Las claves del mapa real son tuplas {Tipo, Componente}; JSON exige strings,
  %% asi que se aplanan a "tipo:componente".
  Cuerpo = #{existencias =>
               maps:from_list([{aplanar(K), N} || {K, N} <- maps:to_list(Existencias)])},
  Req = cowboy_req:reply(200, cabeceras_json(), p44_json:encode(Cuerpo), Req0),
  {ok, Req, State}.

aplanar({Tipo, Comp}) ->
  <<(atom_to_binary(Tipo, utf8))/binary, $:, (atom_to_binary(Comp, utf8))/binary>>.

cabeceras_json() -> #{<<"content-type">> => <<"application/json">>}.
