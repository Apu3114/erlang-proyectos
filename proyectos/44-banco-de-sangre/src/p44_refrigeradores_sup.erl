%% Supervisor dinámico de refrigeradores: uno por refrigerador físico.
-module(p44_refrigeradores_sup).
-behaviour(supervisor).

-export([start_link/0, crear/2]).
-export([init/1]).

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% Un refrigerador (Id) guarda el lote Lote.
crear(Id, Lote) ->
  supervisor:start_child(?MODULE, [Id, Lote]).

init([]) ->
  Hijo = #{id => p44_refrigerador,
           start => {p44_refrigerador, start_link, []},
           restart => permanent,
           shutdown => 5000,
           type => worker},
  {ok, {#{strategy => simple_one_for_one, intensity => 10, period => 60}, [Hijo]}}.
