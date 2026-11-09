-module(p44_json_tests).
-include_lib("eunit/include/eunit.hrl").

%% ---------- encode ----------

encode_escalares_test_() ->
  [?_assertEqual(<<"true">>, iolist_to_binary(p44_json:encode(true))),
   ?_assertEqual(<<"false">>, iolist_to_binary(p44_json:encode(false))),
   ?_assertEqual(<<"null">>, iolist_to_binary(p44_json:encode(null))),
   ?_assertEqual(<<"null">>, iolist_to_binary(p44_json:encode(undefined))),
   ?_assertEqual(<<"42">>, iolist_to_binary(p44_json:encode(42))),
   ?_assertEqual(<<"-7">>, iolist_to_binary(p44_json:encode(-7))),
   ?_assertEqual(<<"\"hola\"">>, iolist_to_binary(p44_json:encode(<<"hola">>))),
   ?_assertEqual(<<"\"a_pos\"">>, iolist_to_binary(p44_json:encode(a_pos)))].

encode_escapa_comillas_y_saltos_test() ->
  Bin = iolist_to_binary(p44_json:encode(<<"di \"hola\"\ny adios">>)),
  ?assertEqual(<<"\"di \\\"hola\\\"\\ny adios\"">>, Bin).

encode_lista_test() ->
  ?assertEqual(<<"[1,2,3]">>, iolist_to_binary(p44_json:encode([1, 2, 3]))).

encode_lista_vacia_test() ->
  ?assertEqual(<<"[]">>, iolist_to_binary(p44_json:encode([]))).

encode_mapa_test() ->
  %% El orden de las claves en un mapa pequeno es estable; se decodifica de vuelta
  %% para no depender de ese orden exacto en el texto.
  Bin = iolist_to_binary(p44_json:encode(#{tipo => a_pos, existencias => 3})),
  {ok, Decodificado} = p44_json:decode(Bin),
  ?assertEqual(#{<<"tipo">> => <<"a_pos">>, <<"existencias">> => 3}, Decodificado).

encode_mapa_vacio_test() ->
  ?assertEqual(<<"{}">>, iolist_to_binary(p44_json:encode(#{}))).

encode_anidado_test() ->
  Dato = #{unidades => [#{id => 1, tipo => o_neg}, #{id => 2, tipo => a_pos}]},
  Bin = iolist_to_binary(p44_json:encode(Dato)),
  {ok, D} = p44_json:decode(Bin),
  ?assertEqual(#{<<"unidades">> => [#{<<"id">> => 1, <<"tipo">> => <<"o_neg">>},
                                     #{<<"id">> => 2, <<"tipo">> => <<"a_pos">>}]}, D).

%% ---------- decode ----------

decode_objeto_simple_test() ->
  ?assertEqual({ok, #{<<"a">> => 1, <<"b">> => <<"x">>}},
               p44_json:decode(<<"{\"a\": 1, \"b\": \"x\"}">>)).

decode_arreglo_test() ->
  ?assertEqual({ok, [1, 2, 3]}, p44_json:decode(<<"[1,2,3]">>)).

decode_anidado_test() ->
  ?assertEqual({ok, #{<<"x">> => [1, #{<<"y">> => true}]}},
               p44_json:decode(<<"{\"x\":[1,{\"y\":true}]}">>)).

decode_numeros_test_() ->
  [?_assertEqual({ok, 0}, p44_json:decode(<<"0">>)),
   ?_assertEqual({ok, 42}, p44_json:decode(<<"42">>)),
   ?_assertEqual({ok, -7}, p44_json:decode(<<"-7">>)),
   ?_assertEqual({ok, 3.5}, p44_json:decode(<<"3.5">>)),
   ?_assertEqual({ok, -0.25}, p44_json:decode(<<"-0.25">>)),
   ?_assertEqual({ok, 150.0}, p44_json:decode(<<"1.5e2">>)),
   ?_assertEqual({ok, 0.015}, p44_json:decode(<<"1.5e-2">>))].

decode_escapes_test() ->
  {ok, Bin} = p44_json:decode(<<"\"linea1\\nlinea2 \\\"cita\\\"\"">>),
  ?assertEqual(<<"linea1\nlinea2 \"cita\"">>, Bin).

decode_espacios_alrededor_test() ->
  ?assertEqual({ok, #{<<"a">> => 1}}, p44_json:decode(<<"  { \"a\" : 1 }  ">>)).

decode_invalido_test_() ->
  [?_assertMatch({error, _}, p44_json:decode(<<"{sin comillas: 1}">>)),
   ?_assertMatch({error, _}, p44_json:decode(<<"[1, 2,">>)),
   ?_assertMatch({error, _}, p44_json:decode(<<"">>)),
   ?_assertMatch({error, _}, p44_json:decode(<<"123 texto_sobrante">>))].

%% ---------- ida y vuelta ----------

ida_y_vuelta_test() ->
  %% unicode:characters_to_binary/1, no el literal <<"...">> directo: un literal
  %% binario con caracteres fuera de latin1 depende de como el compilador interprete
  %% la codificacion del archivo fuente, y puede no producir bytes UTF-8 reales.
  Nombre = unicode:characters_to_binary("café ☕"),
  Original = #{<<"nombre">> => Nombre, <<"activo">> => true,
               <<"cantidad">> => 12, <<"precio">> => 3.75,
               <<"etiquetas">> => [<<"a">>, <<"b">>], <<"nulo">> => null},
  Bin = iolist_to_binary(p44_json:encode(Original)),
  ?assertEqual({ok, Original}, p44_json:decode(Bin)).
