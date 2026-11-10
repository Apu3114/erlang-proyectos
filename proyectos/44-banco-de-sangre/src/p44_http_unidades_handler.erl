%% Listado y detalle de los procesos de unidad para la interfaz.
-module(p44_http_unidades_handler).
-export([init/2, resumen/1, id/1, responder/3]).

init(Req0, State) ->
  Respuesta = case cowboy_req:binding(id, Req0, undefined) of
    undefined -> listar();
    Bin -> detalle(Bin)
  end,
  {Codigo, Cuerpo} = Respuesta,
  {ok, responder(Codigo, Cuerpo, Req0), State}.

listar() ->
  try
    Pids = [Pid || {_, Pid, _, _} <- supervisor:which_children(p44_unidades_sup), is_pid(Pid)],
    Unidades = [resumen(p44_unidad:estado(Pid)) || Pid <- Pids],
    {200, #{unidades => lists:sort(fun(A, B) -> maps:get(id, A) < maps:get(id, B) end, Unidades)}}
  catch exit:_ -> {503, #{error => servicio_no_disponible}}
  end.

detalle(Bin) ->
  case id(Bin) of
    {ok, Id} ->
      try {200, resumen(p44_unidad:estado(Id))}
      catch exit:_ -> {404, #{error => unidad_no_encontrada}}
      end;
    error -> {400, #{error => id_invalido}}
  end.

%% No crear atomos con un id recibido por HTTP (nombre/1 usa list_to_atom).
%% Solo permitir IDs que ya existen en la bitacora y tienen proceso vivo.
id(Bin) when is_binary(Bin), byte_size(Bin) =< 9 ->
  try
    Id = binary_to_integer(Bin),
    case Id > 0 andalso lists:any(fun(#{id := N}) -> N =:= Id end, p44_bitacora:unidades()) of
      true -> {ok, Id};
      false -> error
    end
  catch error:_ -> error
  end;
id(_) -> error.

resumen({Estado, Datos}) ->
  Campos = [id, tipo, componente, lote, donante, caduca_en, reserva_hasta],
  Base = maps:with(Campos, Datos),
  Base#{estado => Estado,
        solicitante => texto(maps:get(solicitante, Datos, undefined)),
        receptor => texto(maps:get(receptor, Datos, undefined))}.

texto(undefined) -> null;
texto({http, Bin}) when is_binary(Bin) -> Bin;
texto(Bin) when is_binary(Bin) -> Bin;
texto(A) when is_atom(A) -> atom_to_binary(A, utf8);
texto(Term) -> iolist_to_binary(io_lib:format("~tp", [Term])).

responder(Codigo, Cuerpo, Req) ->
  cowboy_req:reply(Codigo, #{<<"content-type">> => <<"application/json; charset=utf-8">>,
                            <<"cache-control">> => <<"no-store">>},
                   p44_json:encode(Cuerpo), Req).
