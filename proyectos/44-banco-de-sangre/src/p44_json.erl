%% Codificador/decodificador JSON propio, minimo y autocontenido: el proyecto no trae
%% ninguna libreria JSON como dependencia (solo cowboy y recon), asi que en vez de
%% agregar una mas, se escribio esta, pensada solo para las formas que usa esta API
%% (mapas, listas, atomos, numeros, binarios). No es un parser JSON de proposito
%% general (no cubre todos los casos raros del estandar), pero cubre bien lo que
%% entra y sale de /api y /metrics, y esta probado contra eso.
-module(p44_json).

-export([encode/1, decode/1]).

%% ---------- Codificar ----------

%% Devuelve iodata (binario o lista de binarios), no un binario aplanado, por
%% eficiencia; cowboy_req:reply acepta iodata directamente.
encode(true) -> <<"true">>;
encode(false) -> <<"false">>;
encode(null) -> <<"null">>;
encode(undefined) -> <<"null">>;
encode(N) when is_integer(N) -> integer_to_binary(N);
encode(N) when is_float(N) -> float_to_binary(N, [{decimals, 6}, compact]);
encode(B) when is_binary(B) -> cadena(B);
encode(A) when is_atom(A) -> cadena(atom_to_binary(A, utf8));
encode(L) when is_list(L) ->
  [$[, lists:join($,, [encode(El) || El <- L]), $]];
encode(M) when is_map(M) ->
  Pares = [[clave(K), $:, encode(V)] || {K, V} <- maps:to_list(M)],
  [${, lists:join($,, Pares), $}].

%% Las claves de un objeto JSON tienen que ser string; aceptamos atomo o binario.
clave(K) when is_atom(K) -> cadena(atom_to_binary(K, utf8));
clave(K) when is_binary(K) -> cadena(K).

cadena(B) when is_binary(B) ->
  [$", escapar(B), $"].

escapar(B) -> escapar(B, []).

escapar(<<>>, Acc) -> lists:reverse(Acc);
escapar(<<$", Resto/binary>>, Acc) -> escapar(Resto, [$", $\\ | Acc]);
escapar(<<$\\, Resto/binary>>, Acc) -> escapar(Resto, [$\\, $\\ | Acc]);
escapar(<<$\n, Resto/binary>>, Acc) -> escapar(Resto, [$n, $\\ | Acc]);
escapar(<<$\r, Resto/binary>>, Acc) -> escapar(Resto, [$r, $\\ | Acc]);
escapar(<<$\t, Resto/binary>>, Acc) -> escapar(Resto, [$t, $\\ | Acc]);
escapar(<<C/utf8, Resto/binary>>, Acc) when C < 16#20 ->
  Hex = io_lib:format("\\u~4.16.0b", [C]),
  escapar(Resto, lists:reverse(Hex) ++ Acc);
escapar(<<C/utf8, Resto/binary>>, Acc) ->
  escapar(Resto, [<<C/utf8>> | Acc]).

%% ---------- Decodificar ----------

%% {ok, Termino} | {error, Razon}. Objetos -> #{BinarioClave => Valor} (claves SIEMPRE
%% binarias, nunca atomos: los datos vienen de fuera, convertir a atomo sin lista
%% blanca podria agotar la tabla de atomos). Arreglos -> listas. true/false/null -> esos
%% atomos. Numeros -> entero o float segun corresponda.
decode(Bin) when is_binary(Bin) ->
  try
    {Valor, Resto0} = valor(saltar_espacio(Bin)),
    case saltar_espacio(Resto0) of
      <<>> -> {ok, Valor};
      _ -> {error, texto_sobrante}
    end
  catch
    throw:Razon -> {error, Razon};
    error:_ -> {error, json_invalido}
  end.

saltar_espacio(<<C, Resto/binary>>) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
  saltar_espacio(Resto);
saltar_espacio(Bin) -> Bin.

valor(<<"true", R/binary>>) -> {true, R};
valor(<<"false", R/binary>>) -> {false, R};
valor(<<"null", R/binary>>) -> {null, R};
valor(<<$", R/binary>>) -> cadena_json(R, []);
valor(<<${, R/binary>>) -> objeto(saltar_espacio(R), #{});
valor(<<$[, R/binary>>) -> arreglo(saltar_espacio(R), []);
valor(<<C, _/binary>> = B) when C =:= $-; C >= $0, C =< $9 -> numero(B);
valor(_) -> throw(valor_inesperado).

objeto(<<$}, R/binary>>, Acc) -> {Acc, R};
objeto(<<$", R/binary>>, Acc) ->
  {Clave, R1} = cadena_json(R, []),
  R2 = saltar_espacio(R1),
  <<$:, R3/binary>> = R2,
  {Val, R4} = valor(saltar_espacio(R3)),
  Acc1 = Acc#{Clave => Val},
  case saltar_espacio(R4) of
    <<$,, R5/binary>> -> objeto(saltar_espacio(R5), Acc1);
    <<$}, R5/binary>> -> {Acc1, R5};
    _ -> throw(objeto_mal_formado)
  end;
objeto(_, _) -> throw(objeto_mal_formado).

arreglo(<<$], R/binary>>, Acc) -> {lists:reverse(Acc), R};
arreglo(Bin, Acc) ->
  {Val, R1} = valor(saltar_espacio(Bin)),
  case saltar_espacio(R1) of
    <<$,, R2/binary>> -> arreglo(saltar_espacio(R2), [Val | Acc]);
    <<$], R2/binary>> -> {lists:reverse([Val | Acc]), R2};
    _ -> throw(arreglo_mal_formado)
  end.

cadena_json(<<$", R/binary>>, Acc) -> {iolist_to_binary(lists:reverse(Acc)), R};
cadena_json(<<$\\, $", R/binary>>, Acc) -> cadena_json(R, [$" | Acc]);
cadena_json(<<$\\, $\\, R/binary>>, Acc) -> cadena_json(R, [$\\ | Acc]);
cadena_json(<<$\\, $/, R/binary>>, Acc) -> cadena_json(R, [$/ | Acc]);
cadena_json(<<$\\, $n, R/binary>>, Acc) -> cadena_json(R, [$\n | Acc]);
cadena_json(<<$\\, $r, R/binary>>, Acc) -> cadena_json(R, [$\r | Acc]);
cadena_json(<<$\\, $t, R/binary>>, Acc) -> cadena_json(R, [$\t | Acc]);
cadena_json(<<$\\, $u, Hex:4/binary, R/binary>>, Acc) ->
  Codigo = binary_to_integer(Hex, 16),
  cadena_json(R, [<<Codigo/utf8>> | Acc]);
cadena_json(<<C/utf8, R/binary>>, Acc) -> cadena_json(R, [<<C/utf8>> | Acc]);
cadena_json(<<>>, _Acc) -> throw(cadena_sin_cerrar).

numero(Bin) ->
  {Signo, Bin1} = case Bin of
                     <<$-, R/binary>> -> {<<"-">>, R};
                     _ -> {<<>>, Bin}
                   end,
  {Enteros, Bin2} = digitos(Bin1),
  {Decimales, EsFloat1, Bin3} = case Bin2 of
                                   <<$., R2/binary>> ->
                                     {D, R3} = digitos(R2),
                                     {<<$., D/binary>>, true, R3};
                                   _ -> {<<>>, false, Bin2}
                                 end,
  {Exponente, EsFloat2, Bin4} = case Bin3 of
                                   <<E, R4/binary>> when E =:= $e; E =:= $E ->
                                     {EsSigno, R5} = case R4 of
                                                        <<Signo2, R6/binary>>
                                                          when Signo2 =:= $+; Signo2 =:= $- ->
                                                          {<<Signo2>>, R6};
                                                        _ -> {<<>>, R4}
                                                      end,
                                     {DE, R7} = digitos(R5),
                                     {<<$e, EsSigno/binary, DE/binary>>, true, R7};
                                   _ -> {<<>>, false, Bin3}
                                 end,
  Texto = <<Signo/binary, Enteros/binary, Decimales/binary, Exponente/binary>>,
  case EsFloat1 orelse EsFloat2 of
    true -> {binary_to_float(Texto), Bin4};
    false -> {binary_to_integer(Texto), Bin4}
  end.

%% Consume uno o mas digitos ASCII de la cabeza de Bin. Devuelve {Digitos, Resto}
%% con Digitos como binario (p.ej. <<"042">>); exige al menos uno, si no hay lanza.
digitos(Bin) ->
  case digitos(Bin, []) of
    {[], _} -> throw(numero_mal_formado);
    {Rev, Resto} -> {iolist_to_binary(lists:reverse(Rev)), Resto}
  end.

digitos(<<C, R/binary>>, Acc) when C >= $0, C =< $9 -> digitos(R, [C | Acc]);
digitos(Bin, Acc) -> {Acc, Bin}.
