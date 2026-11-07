# Contexto completo: proyecto #44 — Banco de sangre (Erlang/OTP)

Eres un agente de código (OpenCode) que va a continuar un proyecto escolar de Erlang/OTP.
Lee todo este documento antes de tocar nada. No pidas confirmación para pasos de rutina
(compilar, correr tests, hacer commit); sí pide confirmación antes de cualquier `git push`
a `main` si detectas conflictos, y antes de borrar o sobrescribir algo que no hayas creado tú.

## 0. Credenciales — LEE ESTO PRIMERO

El repo remoto es `https://github.com/Apu3114/erlang-proyectos.git`, rama `main`.
El token de GitHub está en la variable de entorno `GITHUB_TOKEN` (NO está en ningún
archivo). Para hacer push sin que el token quede escrito en el working tree:

```bash
AUTH=$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 -w0)
git -c http.extraheader="Authorization: Basic $AUTH" push origin HEAD:main
```

Reglas estrictas:
- NUNCA escribas el valor de `GITHUB_TOKEN` en un archivo, commit, log, o lo imprimas
  por pantalla.
- NUNCA lo pongas en `rebar.config`, `.erlang.cookie`, `config/sys.config` ni ningún
  archivo versionado.
- Si `GITHUB_TOKEN` no existe en el entorno, detente y pide al usuario que lo configure
  con `export GITHUB_TOKEN=...` — no inventes uno ni intentes otro método de auth.
- Antes de cada push, corre `git status` y revisa que no se esté subiendo nada fuera de
  `proyectos/44-banco-de-sangre/`.

## 1. Dónde estás parado

- Entorno: Raspberry Pi 5 (aarch64) en una VM de Corellium, Debian 11 (bullseye).
- Erlang/OTP **27.3.4.19** instalado con `kerl` en `~/erlang/27.3.4.19` (activado vía
  `.bashrc`). rebar3 **3.28.0** en `/usr/local/bin/rebar3`.
- Repo clonado en `~/erlang-proyectos`. El proyecto a trabajar es
  `~/erlang-proyectos/proyectos/44-banco-de-sangre/` — SOLO toca archivos dentro de
  esta carpeta, salvo que se indique lo contrario.
- `config/` de Debian: el `sources.list` fue parchado para apuntar
  `security.debian.org` → `archive.debian.org` (bullseye ya salió de soporte). No lo
  toques, ya funciona.

Comandos de verificación que debes poder correr sin fallas antes de empezar:

```bash
cd ~/erlang-proyectos/proyectos/44-banco-de-sangre
rebar3 compile
rebar3 eunit
```

Al día de hoy esto da **31 tests, 0 failures**. Si no, detente y reporta el error antes
de seguir construyendo encima.

## 2. Qué es este proyecto

Enunciado completo en `problema/readme.md` (léelo). Resumen: simular un banco de
sangre con 8 tipos sanguíneos, 3 componentes (glóbulos rojos, plasma, plaquetas) y 300
unidades. El sistema debe:
- Llevar inventario por tipo, componente, lote y caducidad.
- Asignar respetando compatibilidad ABO/Rh y FEFO (primero en caducar, primero en salir).
- Reservar sangre para cirugías programadas.
- Atender un protocolo de emergencia.
- Emitir alertas de nivel crítico.
- Mantener trazabilidad donante → unidad → receptor.
- Sobrevivir a fallas: no asignar nunca una unidad vencida, no asignar la misma unidad
  dos veces, retirar de inmediato las unidades de un donante que resulta positivo tarde.

Entregables pedidos (ver `problema/readme.md` para el detalle exacto):
1. Diseño OTP explicado y justificado.
2. Simulación del escenario (accidente de 20 unidades de O negativo en una hora,
   refrigerador que falla).
3. Lista de supuestos propios y de cifras verificadas (vida útil, intervalo entre
   donaciones, NOM-253-SSA1-2012).
4. Prueba de caos documentada (qué mataste, qué esperabas, qué ocurrió).
5. `rebar3 compile` y `rebar3 eunit` en verde, capturas de Stitch y de la app si hay
   interfaz.

## 3. Decisión de diseño central (NO LA CAMBIES sin discutirlo)

**Cada unidad de sangre es un proceso** (`gen_statem`), dueño exclusivo de su propio
estado. Esto es lo que resuelve, por construcción, los casos difíciles del enunciado:
- Solo la unidad puede aceptar una reserva → nunca se asigna dos veces.
- La unidad verifica su propia caducidad al reservar y al asignar, no solo con un
  temporizador → nunca se asigna vencida.
- Si una unidad falla, no afecta a las demás (300 procesos es trivial para la BEAM).

300 unidades es una cantidad pequeña para Erlang: no optimices prematuramente por
"demasiados procesos", ese no es el cuello de botella de este proyecto.

## 4. Árbol de supervisión actual (ya implementado, no lo rehagas)

```
p44_banco_de_sangre_sup   (rest_for_one — el orden ES el orden de dependencia)
├─ p44_pg                  pg:start_link(p44_pg) — grupos de procesos
├─ p44_bitacora            ETS con el historial de cada unidad; fuente de recuperación
├─ p44_unidades_sup        supervisor dinámico (simple_one_for_one)
│    └─ p44_unidad ×300     gen_statem: disponible|reservada|asignada|caducada|
│                            retirada|comprometida
├─ p44_refrigeradores_sup  supervisor dinámico
│    └─ p44_refrigerador    uno por lote; falla → compromete todas las unidades del lote
├─ p44_repoblador           recrea unidades y refrigeradores desde la bitácora si el
│                            supervisor dinámico muere (los hijos no sobreviven a eso)
├─ p44_inventario           índice FEFO + política de sustitución por compatible
├─ p44_alertas               vigila niveles por tipo/componente, avisa por transición
└─ p44_banco_de_sangre_server  (esqueleto original del repo, sin tocar su contrato)
```

Puntos de diseño que debes entender antes de modificar algo:
- **El índice del inventario es solo una pista, nunca la autoridad.** La unidad decide.
  Si reservas desde el índice y la unidad rechaza, el inventario reintenta con la
  siguiente. NUNCA cambies esto para que el inventario "decida" directamente — rompe
  la garantía de no doble asignación.
- **La bitácora (ETS) es el punto único de falla conocido**, documentado y demostrado
  por la prueba de caos (`p44_caos`, experimento 6). Si tienes tiempo, la mejora
  natural es persistirla a disco (ver sección 6, es la primera tarea pendiente sugerida).
- Las unidades se agrupan con `pg` por `{lote, L}` y por `{donante, D}` para que
  refrigeradores y retiros por donante las encuentren sin recorrer las 300.

## 5. Inventario de módulos (todos en `src/`, ya implementados y probados)

| Módulo | Responsabilidad |
|---|---|
| `p44_unidad` | Unidad de sangre (gen_statem) |
| `p44_bitacora` | Historial ETS por unidad y por refrigerador |
| `p44_unidades_sup` / `p44_refrigeradores_sup` | Supervisores dinámicos |
| `p44_inventario` | Índice FEFO + asignación |
| `p44_compatibilidad` | Reglas ABO/Rh puras (sin procesos) |
| `p44_refrigerador` | Falla de refrigeración por lote |
| `p44_alertas` | Niveles críticos, aviso por transición (no repite) |
| `p44_donantes` | Retiro inmediato por donante positivo tardío |
| `p44_repoblador` | Recuperación tras caída de un supervisor dinámico |
| `p44_simulador` | Genera las 300 unidades y corre el escenario del enunciado |
| `p44_caos` | Prueba de caos: mata procesos bajo carga y verifica recuperación |

Tests espejo en `test/`, uno por módulo de dominio, más `p44_simulador_tests.erl` y
`p44_caos_tests.erl`. Todos usan el patrón `{setup, fun arrancar/0, fun detener/1, ...}`
que arranca `p44_banco_de_sangre_sup` completo — síguelo para cualquier test nuevo.

Comandos útiles ya verificados que funcionan en este entorno:

```bash
# Compilar y correr todo
rebar3 compile && rebar3 eunit

# Shell interactivo para probar el escenario y el caos
rebar3 shell
```

```erlang
%% Dentro del shell:
p44_simulador:reiniciar().
logger:set_primary_config(level, error).   %% silencia WARNING REPORT ruidosos
p44_simulador:correr(#{imprimir => true}).
p44_simulador:reiniciar().
p44_caos:correr(#{imprimir => true}).      %% el último experimento destruye el inventario a propósito
```

## 6. Lo que falta — en este orden de prioridad

### 6.1 README.md del proyecto

**Ya existe un borrador completo, pegado íntegro en el Anexo A de este mismo
documento.** Tu primera tarea es:

1. Compararlo contra el `README.md` que YA esté en el repo (puede que ya se haya
   subido una versión; si existe, revisa si es igual o una versión más vieja).
2. Si no existe o es una versión vieja, escribe/sobreescribe
   `proyectos/44-banco-de-sangre/README.md` con el contenido del Anexo A.
3. Completa la tabla "## Equipo" con los datos reales si el usuario te los da;
   si no, pregúntale.
4. **No inventes ni cambies las cifras médicas/normativas** de la tabla de
   verificación (sección "Cifras del enunciado: verificación" del Anexo A) — esa
   tabla ya fue verificada contra el texto oficial de la NOM-253-SSA1-2012. La
   única celda marcada como pendiente es la vida útil de las plaquetas (no se
   localizó el número exacto en la lectura de la norma que se hizo) — si quieres
   cerrarla, busca el capítulo 8 de la NOM-253-SSA1-2012 (texto completo en
   `https://farmacopea.org.mx/Repositorio/LegislacionFiles/NOM-253-SSA1-2012_26oct12.pdf`)
   y actualiza esa fila citando la fuente; si no la encuentras, déjala como
   "no verificado" — no pongas un número sin fuente.
5. Haz commit: `git commit -m "p44: README con diseño, supuestos y cifras verificadas"`.

### 6.2 Pantallas en Google Stitch

Este es el prompt exacto que ya está en `design/PROMPT_STITCH.md` del repo,
pegado aquí para que lo tengas sin necesidad de leer el archivo:

```
# Prompt para Google Stitch — #44 Banco de sangre

Disena la interfaz de: **Banco de sangre** (Salud).
Contexto: tipos, caducidad y emergencias.

Pantallas minimas:
1. Dashboard principal con el estado en tiempo real.
2. Detalle de un elemento (uno de los procesos del dominio).
3. Historial / bitacora de eventos y alertas.

Requisitos: legible en celular, colores de estado (ok / alerta / falla), espanol.

Exporta el zip desde Stitch y descomprimelo en esta carpeta (`design/`),
incluyendo `DESIGN.md`.
```

**Importante: Google Stitch es una herramienta web (`stitch.withgoogle.com`),
no una terminal.** Si no tienes una herramienta de navegador/browser-use
disponible en este entorno, NO intentes simularlo ni generar las pantallas tú
mismo en HTML como sustituto silencioso — eso no es lo que pide el enunciado.
En su lugar:

1. Dile al usuario, explícitamente, estos pasos a seguir él mismo:
   - Abrir `https://stitch.withgoogle.com` con su cuenta de Google.
   - Crear un proyecto nuevo y pegar el prompt de arriba tal cual.
   - Generar las 3 pantallas (dashboard, detalle, bitácora/historial).
   - Exportar el proyecto como zip.
   - Subir ese zip a `proyectos/44-banco-de-sangre/design/` en su fork, o
     pasártelo a ti para que lo descomprimas y lo organices.
2. Si SÍ tienes una herramienta de automatización de navegador conectada en
   este entorno, puedes intentar hacerlo tú, pero avisa primero al usuario qué
   vas a hacer y pide confirmación antes de interactuar con su cuenta de
   Google — no asumas que tienes permiso implícito.
3. Una vez tengas los archivos exportados (los ponga el usuario o los generes
   tú), descomprímelos en `design/`, asegúrate de que quede un `DESIGN.md`
   describiendo las pantallas (como pide el repo), y haz commit.

No marques esta tarea como completa si solo generaste una interpretación propia
sin pasar por Stitch — el enunciado pide explícitamente esa herramienta.

### 6.3 Persistir la bitácora a disco

Resuelve el hallazgo del experimento 6 de `p44_caos` (ver Anexo A, sección
"Prueba de caos"). Opcional pero recomendado. `dets` o un volcado periódico de
la ETS a disco es suficiente para el alcance del proyecto.

### 6.4 API con cowboy

`cowboy` y `recon` ya están en `rebar.config` y en el `.app.src` como
dependencias, pero no hay ningún módulo que las use todavía. Mínimo esperado
según `problema/readme.md`:
- `POST /api/solicitudes` → llama a `p44_inventario:solicitar/4`
- `GET /api/inventario` → llama a `p44_inventario:existencias/0`
- SSE o WebSocket que reenvíe los mensajes que llegan a un proceso suscrito con
  `p44_alertas:suscribir/0`
- `/metrics` con datos básicos: unidades por tipo, próximas a caducar,
  solicitudes urgentes atendidas (derívalas de `p44_bitacora` y `p44_inventario`)

### 6.5 Release + systemd

La sección `relx` ya existe en `rebar.config`. Falta el archivo de servicio
systemd para que arranque solo en la Raspberry Pi real.

## 7. Convenciones a seguir

- Comentarios y nombres de funciones en español, como el resto del código (`reservar`,
  `asignar`, `ahora`, `vencida`, etc.) — sé consistente con lo ya escrito.
  Átomos de estado y claves de mapas también en español (`disponible`, `reservada`,
  `caduca_en`, `donante`).
- Cada módulo nuevo necesita su test en `test/` siguiendo el patrón `{setup, ...}` ya
  usado.
- Antes de cualquier commit: `rebar3 compile` (sin warnings — el proyecto compila con
  `+warnings_as_errors` en CI si lo agregas) y `rebar3 eunit` en verde. Si rompes algo
  existente, arréglalo antes de seguir, no lo dejes para después.
- Mensajes de commit cortos, en español, con el formato `p44: <qué cambia>` (sigue el
  historial con `git log --oneline` para ver el estilo exacto).
- No reescribas módulos ya hechos (sección 5) a menos que el usuario lo pida
  explícitamente o encuentres un bug real — en ese caso, explica el bug antes de
  tocar el código.

## 8. Qué preguntarle al usuario (Apu, estudiante del ITT) si algo no está claro

- Si vas a tomar una decisión de diseño que no esté ya cubierta en la sección 3 o 4
  (por ejemplo, cómo modelar las emergencias sin tipificar, o cómo priorizar colas de
  solicitudes), pregúntale primero — es material de su entrega y debe poder
  justificarlo él mismo ante su profesor.
- Si no tienes forma de verificar una cifra médica/normativa (NOM-253, vidas útiles),
  no la inventes: dile que la verifique él y deja el espacio marcado en el README.
- Fecha límite de entrega: pregúntasela si no la tienes, para priorizar qué recortar
  (lo primero que se recorta si falta tiempo es la API web y las pantallas de Stitch,
  el núcleo de Erlang/OTP y el README valen más).


---

# ANEXO A — Borrador completo del README.md del proyecto

Este es el contenido exacto a usar para `proyectos/44-banco-de-sangre/README.md` en la tarea 6.1. Cópialo tal cual (ajustando solo la tabla de equipo si el usuario te da esos datos) salvo que el usuario pida cambios explícitos.

```markdown
# #44 — Banco de sangre

**Dominio:** Salud · Simulación educativa en Erlang/OTP

Un banco de sangre simulado donde **cada unidad de sangre es un proceso**. El sistema controla el inventario por tipo, componente, lote y caducidad; asigna respetando compatibilidad ABO/Rh y FEFO (primero en caducar, primero en salir); reserva para cirugías; alerta niveles críticos; retira unidades de un donante con prueba positiva tardía; y conserva la trazabilidad donante → unidad → receptor. Se recupera solo cuando se le matan procesos.

## Equipo

| Rol | Integrante |
|---|---|
| Backend (OTP) | _(completar)_ |
| Frontend (Stitch + cowboy) | _(completar)_ |
| Ops/QA | _(completar)_ |

## Entorno y arranque

Se desarrolló y probó en una máquina virtual Raspberry Pi 5 (aarch64) de Corellium con Debian 11, con **Erlang/OTP 27.3.4.19** (compilado con kerl) y **rebar3 3.28.0**. Los paquetes de Debian 11 no traen OTP 27 ni rebar3, y el repositorio de seguridad de esa versión pasó a `archive.debian.org`.

```bash
rebar3 compile
rebar3 eunit          # 31 pruebas
rebar3 shell
```

Dentro del shell:

```erlang
p44_simulador:reiniciar().                    % arranca el banco vacío
p44_simulador:correr(#{imprimir => true}).    % escenario del enunciado
p44_simulador:reiniciar().
p44_caos:correr(#{imprimir => true}).         % prueba de caos (el último experimento destruye el inventario a propósito)
```

## Diseño OTP

### La idea central: la unidad de sangre es un proceso

Cada unidad es un `gen_statem` (`p44_unidad`) con los estados **disponible, reservada, asignada, caducada, retirada y comprometida**. La unidad es la única dueña de su estado. Eso responde casi solo a los casos difíciles, porque todos son cuestiones del estado de **una unidad concreta**:

- Una unidad no puede asignarse dos veces: solo ella puede aceptar una reserva, y lo hace una vez.
- Una unidad vencida no se asigna: ella misma verifica su caducidad (ver pregunta guía 2).
- Si falla una unidad, no se afectan las demás.

300 procesos son una cantidad trivial para la VM de Erlang, así que el costo de tener uno por unidad no es un problema.

### Árbol de supervisión

```
p44_banco_de_sangre_sup   (rest_for_one)
├─ p44_pg                  grupos de procesos (lotes, donantes, suscriptores de alertas)
├─ p44_bitacora            historial de cada unidad (ETS); fuente de recuperación
├─ p44_unidades_sup        supervisor dinámico
│    └─ p44_unidad ×300     gen_statem, uno por unidad
├─ p44_refrigeradores_sup  supervisor dinámico
│    └─ p44_refrigerador    uno por refrigerador (lote)
├─ p44_repoblador          recrea unidades y refrigeradores desde la bitácora tras una caída
├─ p44_inventario          índice de disponibles + política de asignación
├─ p44_alertas             vigila niveles por tipo y componente
└─ p44_banco_de_sangre_server  (esqueleto original del repo)
```

### Quién reinicia a quién, y por qué

- **`rest_for_one` en la raíz:** el orden de arranque es el orden de dependencia. Si cae un hijo, se reinician él y todos los que van después de él. La bitácora va antes que las unidades porque las unidades se recuperan desde ella.
- **Unidades (`permanent`, supervisor dinámico):** si una unidad muere, se reinicia sola y **reconstruye su estado desde la bitácora** (primer evento = datos base, último evento = estado actual, incluida una reserva viva).
- **Bitácora:** cada transición se anota **antes** de cambiar de estado. Es además la trazabilidad pedida por el enunciado. La tabla ETS es pública (las unidades escriben directo, sin cuello de botella) pero su dueño es un proceso casi vacío, para que casi no falle.
- **Inventario:** el índice es solo una *pista*. La autoridad es la unidad: si el índice está desactualizado, la unidad rechaza la reserva y se prueba con la siguiente, así que nunca se asigna algo inválido. Si el inventario muere, se reconstruye preguntándole a las unidades. Las unidades le avisan sus cambios con un `cast` que nunca bloquea.
- **Repoblador:** los supervisores dinámicos pierden a sus hijos si ellos mismos se caen. Este proceso arranca después de ambos y vuelve a crear unidades y refrigeradores desde la bitácora. Se descubrió al planear la prueba de caos y se corrigió antes de correrla.
- **Refrigerador:** su estado (`operando`/`fallado`) también va a la bitácora. Si se cae después de fallar, al reiniciarse vuelve a comprometer el lote (operación idempotente), incluidas unidades que llegaron mientras tanto.
- **Grupos con `pg`:** cada unidad se une a un grupo por lote y por donante, para que un refrigerador o un retiro por donante encuentren a sus unidades sin recorrer las 300. `pg` quita solo a los procesos que mueren.

### Módulos

| Módulo | Qué hace |
|---|---|
| `p44_unidad` | Unidad de sangre (`gen_statem`): reservar, asignar, liberar, retirar, comprometer, caducar |
| `p44_bitacora` | Historial por unidad y por refrigerador; consultas para repoblar |
| `p44_inventario` | Índice FEFO y política de asignación con sustitución por compatibles |
| `p44_compatibilidad` | Reglas puras: quién puede donarle a quién y orden de preferencia |
| `p44_refrigerador` | Falla de refrigeración: compromete un lote |
| `p44_alertas` | Niveles críticos por tipo y componente, con aviso por transición |
| `p44_donantes` | Retiro inmediato de todo lo de un donante |
| `p44_repoblador` | Recrea lo perdido desde la bitácora |
| `p44_simulador` | Escenario del enunciado e invariantes |
| `p44_caos` | Prueba de caos |

## Preguntas guía

**1. ¿Cuál es la política cuando el tipo exacto se acabó?**
Primero se intenta el tipo exacto. Si no hay, se pasa a los tipos **compatibles ordenados de menor a mayor "versatilidad"** (a cuántos tipos de receptor puede servir ese donante), de modo que la sangre universal (O negativo en glóbulos rojos) se gasta al final y solo si no hay otra opción. Dentro de un mismo tipo se aplica FEFO. Si no queda nada compatible, la solicitud devuelve `sin_existencias` y el nivel ya habrá disparado una alerta.

**2. ¿Cómo se garantiza que una unidad vencida jamás sea asignada?**
Con defensa en capas, todas dentro de la unidad:
1. La unidad **verifica el reloj en el instante de reservar y de asignar**, no solo confía en su temporizador.
2. Un temporizador la pasa a `caducada` al vencer (revisa como máximo cada día y se re-arma, porque los temporizadores de Erlang no aceptan plazos de más de ~49 días y el plasma dura un año).
3. Al salir de `disponible` el inventario la quita del índice y, aunque el índice estuviera desactualizado, la unidad rechazaría la reserva.
4. Una **invariante verificada sobre los historiales completos** comprueba que ninguna unidad fue asignada después de su caducidad (`p44_simulador:invariantes/0`).

## Casos difíciles

- **Sustituir un tipo agotado por uno compatible:** `p44_inventario` + `p44_compatibilidad` (pregunta guía 1).
- **Reserva que no se usó, ¿cuándo se libera?** Cada reserva tiene un plazo explícito (TTL) que fija quien reserva. Al vencer, la unidad vuelve a `disponible`; si ya caducó mientras tanto, pasa a `caducada` en vez de volver al inventario.
- **Prueba positiva tardía de un donante:** `p44_donantes:retirar/2` retira de inmediato todas las unidades de ese donante. Devuelve cuántas se retiraron a tiempo y cuáles **ya se transfundieron, con su receptor**, para avisarles.

## Resultados de la simulación

Escenario (semilla por defecto 42): 8 tipos × 3 componentes, **300 unidades**.

| Fase | Resultado |
|---|---|
| Accidente múltiple | 20 solicitudes de O negativo, **20 surtidas con tipo exacto**; quedan 4 unidades y salta alerta crítica (umbral 5) |
| Pico de cirugías | 50 reservas de A positivo: 40 con tipo exacto y **10 sustituidas por A negativo** (el compatible menos valioso); se opera a 30 |
| Reservas sin usar | Las otras 20 vencen su plazo y **vuelven solas al inventario** |
| Donante positivo tardío | Se retiran sus unidades disponibles; las ya transfundidas se reportan con su receptor |
| Falla de refrigerador | Compromete todas las unidades de su lote; una alerta de otro tipo se dispara como efecto |
| Estado final | 207 disponibles, 50 asignadas, 1 retirada, 42 comprometidas (suman 300) |
| Invariantes | `ok`: ninguna unidad asignada vencida ni transición prohibida en los 300 historiales |

## Prueba de caos

Se mata a procesos clave **mientras una carga de fondo pide y entrega sangre** (≈40 solicitudes por segundo). Al final se revisan las invariantes de todos los historiales.

| # | Qué maté | Qué esperaba | Qué ocurrió |
|---|---|---|---|
| 1 | Una unidad con reserva viva | Se reinicia y conserva su reserva | Volvió con la misma reserva, proceso nuevo |
| 2 | Un refrigerador ya fallado | Sigue fallado y su lote inutilizable | Sigue fallado; 54 unidades del lote, todas inutilizables |
| 3 | El vigilante de alertas | Se reinicia y re-notifica los niveles críticos vigentes | Reinició y re-notificó 8 niveles |
| 4 | El inventario, en plena carga | Reconstruye el índice y coincide con las unidades | Índice igual a las unidades disponibles |
| 5 | El supervisor de unidades (se lleva a las 300) | El repoblador las recrea con su estado | Recuperadas las 300, estados idénticos |
| 6 | **La bitácora** | **Hallazgo esperado:** es el punto único de falla | Se perdieron las 300 unidades y la trazabilidad |

_(Estos son los valores de la corrida de referencia; sustituir por los de tu captura si difieren.)_

**Limitaciones honestas de la prueba:**
- En el experimento 4 no hubo solicitudes interrumpidas durante la caída (el inventario reinicia en milisegundos y ninguna cayó en esa ventana). La prueba demuestra que **se reconstruye correctamente**, no que las solicitudes fallen limpio mientras está caído.
- El experimento 6 **no está resuelto, está documentado**. La bitácora vive en ETS, en memoria. La mejora natural es persistirla a disco; queda como trabajo pendiente.

## Supuestos propios

- **Plantilla de inventario:** las 300 unidades se reparten en 180 glóbulos rojos, 90 plasma y 30 plaquetas, con una distribución de tipos elegida por diseño (no es un dato oficial). Se cargan 24 unidades de O negativo en glóbulos rojos para que el accidente de 20 sea posible y deje el nivel crítico.
- **Umbral crítico:** 5 unidades por tipo y componente, configurable (`umbral_default` y `umbrales` en el entorno de la aplicación). El enunciado no da cifras.
- **Compatibilidad:** glóbulos rojos con ABO y Rh. Plasma y plaquetas comparten una regla simplificada (ABO invertido, Rh ignorado); las plaquetas reales tienen reglas propias.
- **Tiempo comprimido:** las 20 solicitudes del accidente ocurren de inmediato, no repartidas en una hora real.
- **Vida útil usada:** 42 días (rojos), 7 (plaquetas) y 365 (plasma), tomando el extremo alto del rango del enunciado; la vida restante de cada unidad se sortea entre 15 % y 100 %.
- **Lotes y refrigeradores:** un refrigerador por lote; lotes 1–3 para rojos, 4 para plaquetas, 5–6 para plasma. Las condiciones distintas de almacenamiento (temperatura, agitación, congelado) no se modelan, solo la falla.
- **Donantes:** un donante comparte identificador entre los componentes del mismo tipo (rojos, plasma y plaquetas de una misma donación).
- **Emergencia sin tipificar:** se modela como una solicitud de O negativo. No hay una cola con prioridad separada para emergencias.
- **Pruebas de liberación:** las pruebas contra infecciones previas a liberar una unidad no se modelan; solo el retiro posterior por prueba positiva tardía.

## Cifras del enunciado: verificación

Se consultó el texto oficial de la **NOM-253-SSA1-2012** (Diario Oficial de la
Federación, 26 de octubre de 2012; "Para la disposición de sangre humana y sus
componentes con fines terapéuticos"), publicado en
`farmacopea.org.mx/Repositorio/LegislacionFiles/NOM-253-SSA1-2012_26oct12.pdf` y
también disponible en `gob.mx/cnts`.

| Cifra | Lo usado en el código | Verificación | Fuente |
|---|---|---|---|
| Vida útil de glóbulos rojos | 42 días | **Confirmado.** Concentrado eritrocitario, refrigerado entre 1 °C y 6 °C, hasta 42 días (la vigencia exacta depende de la solución anticoagulante/preservante usada, capítulo 8 de la norma) | NOM-253-SSA1-2012, cap. 8 |
| Vida útil del plasma congelado | 365 días | **Confirmado.** Plasma fresco congelado a −18 °C o menos, hasta un año | NOM-253-SSA1-2012, cap. 8 |
| Vida útil de plaquetas | 7 días | **No verificado en la norma.** No se localizó en el texto de la NOM-253 una cifra explícita de vigencia para plaquetas en la lectura realizada (están en el capítulo 8, con condiciones de agitación continua a 20–24 °C, pero no se confirmó el número de días). El valor usado (7 días) es la cifra típica citada en bibliografía médica general, no la norma misma. **Pendiente de que el equipo lo verifique directamente en el capítulo 8 de la norma.** | sin confirmar |
| Intervalo mínimo entre donaciones de sangre total | — (no se modela) | **Confirmado.** 8 semanas entre dos donaciones de sangre total (o entre una de sangre total y una eritroaféresis de bolsa única); 3 meses si la segunda es eritroaféresis de bolsa doble; 4 semanas entre sangre total y una plaquetaféresis/plasmaféresis sin extracción de eritrocitos (tabla 9 de la norma) | NOM-253-SSA1-2012, apartado 7.2.12, tabla 9 |
| Máximo de donaciones de sangre total al año | — (no se modela) | **Confirmado.** 4 veces al año para hombres, 3 para mujeres | NOM-253-SSA1-2012, apartado 7.2.11 |
| Edad y peso mínimos para donar | — (no se modela) | **Confirmado.** Entre 18 y 65 años; peso mínimo 50 kg (70 kg para eritroaféresis de más de una unidad) | NOM-253-SSA1-2012, apartado 6.10.4.2 y 6.10.4.3 |
| Tipos más comunes en México | — (plantilla propia, ver supuestos) | **No verificado.** No se consultó una fuente epidemiológica específica; la distribución de tipos del simulador es una decisión de diseño, no un dato censal | sin consultar |

El intervalo entre donaciones y los límites por donante **no se modelan** en el
código (el simulador no rastrea cuántas veces ha donado una persona en el año);
solo se citan aquí como contexto normativo. Si se quiere modelarlos, es la extensión
natural de `p44_donantes`.

## Estado del proyecto

**Hecho:** dominio completo (unidades, bitácora, inventario, compatibilidad, refrigeradores, alertas, retiro por donante, repoblador), simulador del escenario, prueba de caos y 31 pruebas con `rebar3 eunit` en verde.

**Pendiente (no implementado):**
- [ ] API con cowboy (`POST /api/solicitudes`, `GET /api/inventario`) y SSE de alertas
- [ ] Pantallas en Stitch (`design/PROMPT_STITCH.md`) y capturas
- [ ] Métricas `/metrics` y diagnóstico con recon
- [ ] Release y servicio systemd
- [ ] Persistir la bitácora a disco (resolvería el hallazgo 6 del caos)

```
