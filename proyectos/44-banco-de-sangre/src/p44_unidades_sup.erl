%% Supervisor dinámico: un hijo p44_unidad por cada unidad de sangre.
%% Si una unidad se cae, se reinicia sola y recupera su estado desde la bitácora.
-module(p44_unidades_sup).
-behaviour(supervisor).

-export([start_link/0, crear/1]).
-export([init/1]).

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).

crear(Datos) ->
  supervisor:start_child(?MODULE, [Datos]).

init([]) ->
  Hijo = #{id => p44_unidad,
           start => {p44_unidad, start_link, []},
           restart => permanent,
           shutdown => 5000,
           type => worker},
  {ok, {#{strategy => simple_one_for_one, intensity => 50, period => 60}, [Hijo]}}.
