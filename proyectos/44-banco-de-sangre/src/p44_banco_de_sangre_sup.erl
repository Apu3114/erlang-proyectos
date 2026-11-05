-module(p44_banco_de_sangre_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% rest_for_one: el orden de arranque ES el orden de dependencia.
%%   pg               grupos de procesos (lotes, donantes, suscriptores de alertas)
%%   bitacora         historial; todo lo demás se recupera desde ahí
%%   unidades         supervisor de las unidades de sangre
%%   refrigeradores   supervisor de los refrigeradores (no depende del inventario)
%%   repoblador       recrea unidades y refrigeradores desde la bitácora tras una caída
%%   inventario       índice y asignación; se reconstruye leyendo las unidades
%%   alertas          leen el inventario
%% Si un hijo cae, se reinician él y todos los que van después de él.
init([]) ->
  Children = [
    worker(p44_pg, {pg, start_link, [p44_pg]}),
    worker(p44_bitacora, {p44_bitacora, start_link, []}),
    supervisor(p44_unidades_sup),
    supervisor(p44_refrigeradores_sup),
    worker(p44_repoblador, {p44_repoblador, start_link, []}),
    worker(p44_inventario, {p44_inventario, start_link, []}),
    worker(p44_alertas, {p44_alertas, start_link, []}),
    worker(p44_banco_de_sangre_server, {p44_banco_de_sangre_server, start_link, []})
  ],
  {ok, {#{strategy => rest_for_one, intensity => 10, period => 60}, Children}}.

worker(Id, Start) ->
  #{id => Id, start => Start, restart => permanent, shutdown => 5000, type => worker}.

supervisor(Modulo) ->
  #{id => Modulo, start => {Modulo, start_link, []}, restart => permanent,
    shutdown => infinity, type => supervisor}.
