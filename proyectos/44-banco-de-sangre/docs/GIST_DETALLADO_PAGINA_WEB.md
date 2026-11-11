# Banco de sangre #44 — Investigación, solución OTP y documentación detallada de la web

**Proyecto:** Simulación educativa de banco de sangre con Erlang/OTP  
**Repositorio:** https://github.com/Apu3114/erlang-proyectos/tree/main/proyectos/44-banco-de-sangre  
**Demo pública:** http://54.227.229.168/app/ (solo disponible si el laboratorio AWS Academy está encendido)  
**Estado:** HTTP sin autenticación · Datos ficticios · No es un sistema clínico  

**Video de demostración:** consulta el [apartado para el enlace de Loom](#video-de-demostración-en-loom).

---

## 1. Introducción: tema, problema y objetivo

La sangre es un recurso que depende de donaciones y cuyos componentes tienen una vida útil limitada. Un banco de sangre necesita saber **qué unidades tiene, cuándo caducan, a qué lote pertenecen y cuál es su trazabilidad**. Un accidente puede aumentar de golpe la demanda de un tipo escaso; una cirugía puede reservar una unidad que finalmente no se usa; una falla de almacenamiento puede invalidar un lote. El [enunciado del proyecto #44](https://github.com/Apu3114/erlang-proyectos/blob/main/proyectos/44-banco-de-sangre/problema/readme.md) propone resolver esos problemas con una **simulación educativa**, no con un producto médico.

**Objetivo general:** implementar en Erlang/OTP un sistema concurrente y tolerante a fallas que administre 300 unidades ficticias de 8 tipos sanguíneos y 3 componentes, y ofrecer una interfaz web para observar inventario, lotes, donantes, procesos y bitácora.

**Objetivos concretos:** asignar respetando compatibilidad y FEFO (primero en caducar, primero en salir), reservar y liberar unidades, atender solicitudes O negativo de emergencia, avisar sobre niveles bajos, retirar unidades de un donante con resultado tardío positivo y comprobar que una falla de procesos no elimina la trazabilidad. En esta implementación, la emergencia es una solicitud O−, **no** un protocolo clínico completo ni una cola de prioridad especial.

Esta aplicación permite consultar y operar la simulación: **cada unidad es un proceso Erlang independiente** (`gen_statem`), con estados y reglas propias. La interfaz está en `design/app/index.html` y nginx la sirve desde la VM pública. El backend Cowboy escucha en `127.0.0.1:8080` y nginx publica la API y la web por HTTP/80. Las tres maquetas originales de Google Stitch son referencias visuales; la web operativa es `design/app/`.

**Alcance y precaución:** todos los registros son ficticios. La web carece de autenticación y TLS, por lo que no debe usarse para decisiones clínicas ni contener datos reales de pacientes o donantes.

### 1.1 Investigación del dominio: qué se consultó y qué se implementó

La investigación partió del [enunciado original](https://github.com/Apu3114/erlang-proyectos/blob/main/proyectos/44-banco-de-sangre/problema/readme.md) y de la revisión de la **NOM-253-SSA1-2012, «Para la disposición de sangre humana y sus componentes con fines terapéuticos»**, publicada en el [Diario Oficial de la Federación (26-10-2012)](https://www.dof.gob.mx/nota_detalle.php?codigo=5275587&fecha=26/10/2012). El [README del proyecto, apartado «Cifras del enunciado: verificación»](https://github.com/Apu3114/erlang-proyectos/blob/main/proyectos/44-banco-de-sangre/README.md#cifras-del-enunciado-verificaci%C3%B3n) identifica capítulos y tablas. **La norma se cita como contexto y contraste de cifras: este software no implementa todos sus requisitos ni acredita cumplimiento normativo.**

| Tema investigado | Fuente y hallazgo documentado | Decisión implementada / límite |
|---|---|---|
| Vida útil de glóbulos rojos | NOM-253-SSA1-2012, cap. 8: hasta 42 días entre 1 °C y 6 °C, dependiendo de la solución usada | El simulador usa **42 días**; no mide temperatura ni la solución de conservación. |
| Plaquetas | NOM, apartado 8.4.5, tabla 19: 5 días, ampliables hasta 7 bajo condiciones de reducción o detección bacteriana | Se usan **7 días** como simplificación del escenario, sin modelar esas condiciones. |
| Plasma congelado | El enunciado dice «hasta 1 año»; NOM, apartado 8.6.1.3, tabla 25: hasta **36 meses a ≤ −25 °C** o **3 meses entre −18 °C y −25 °C** | Se usan **365 días** por el enunciado. No se simula temperatura: **un año no se presenta como regla universal de la NOM**. |
| Intervalo de donaciones | NOM, apartado 7.2.12, tabla 9: por ejemplo **8 semanas** entre dos donaciones de sangre total; otros intervalos dependen del procedimiento | Se documenta, **no se comprueba** automáticamente; registrar edad/peso no certifica aptitud. |
| Número de donaciones y criterios básicos | NOM, apartados 7.2.11 y 6.10.4: límites anuales de sangre total y criterios como edad 18–65 años y peso mínimo 50 kg, según procedimiento | Son contexto de la investigación; el formulario ficticio acepta 18–65 años y ≥ 50 kg, pero **no realiza evaluación médica**. |
| Compatibilidad | El enunciado pide ABO/Rh, sustitución y protección del O− en emergencias | En **glóbulos rojos**, ABO y Rh. Para **plasma y plaquetas**, regla simplificada ABO inversa sin Rh; las plaquetas reales requieren reglas específicas. Código: `src/p44_compatibilidad.erl`. |
| Trazabilidad y pruebas | El enunciado destaca el seguimiento donante → unidad → receptor y pruebas infecciosas previas a liberar sangre | La bitácora registra transiciones y el retiro tardío; **no se modelan las pruebas infecciosas previas ni procedimientos médicos de liberación**. |
| Frecuencia de tipos en México | El enunciado menciona tipos comunes y rareza del O−, pero el proyecto **no consultó una fuente epidemiológica específica** | La proporción de tipos en las 300 unidades es una **plantilla inventada**, no una estadística nacional. |

**Investigación del problema técnico:** el inventario puede quedar desactualizado si falla un proceso, y una asignación simultánea no debe entregar dos veces la misma unidad. Se eligió un `gen_statem` por unidad para que ella sea la autoridad de su estado: verifica la caducidad al reservar y despachar. El índice de inventario aplica compatibilidad y FEFO, pero si una unidad rechaza la reserva prueba la siguiente. Los supervisores reinician procesos; `p44_repoblador` y la bitácora ETS + DETS reconstruyen el estado. Durante el despliegue se detectó que claves DETS basadas solo en `unique_integer/1` podían repetirse entre arranques y que `ets:select/2` no garantiza orden temporal; se corrigieron las claves y la reconstrucción. Véase [diseño OTP y persistencia](https://github.com/Apu3114/erlang-proyectos/blob/main/proyectos/44-banco-de-sangre/README.md#dise%C3%B1o-otp).

### 1.2 Supuestos de la simulación (no confundir con hechos clínicos)

- Inventario de referencia: **180 rojos + 90 plasma + 30 plaquetas = 300 unidades**; 24 de O− en rojos para poder atender el accidente ficticio. La vida restante inicial se genera entre 15 % y 100 % de la vida útil elegida.
- **Umbral crítico 5** por combinación tipo/componente: decisión de diseño, configurable, no cifra de la NOM.
- Un refrigerador por lote: inicialmente 3 lotes de rojos, 1 de plaquetas y 2 de plasma; se simula la falla, **no** temperatura, congelación ni agitación.
- El accidente de 20 solicitudes O− «en una hora» se ejecuta de forma comprimida; el pico de cirugías incluye 50 reservas, 30 operaciones y 20 reservas que expiran. Se puede crear un lote o donante ficticio desde la web, pero no se modela el intervalo real entre donaciones.

### 1.3 Evidencia: resultados de una ejecución aislada

En la copia de pruebas de la VM (10-11-2026), `rebar3 compile` y `rebar3 eunit` finalizaron con **76 pruebas, 0 fallos**. Con semilla 42, `p44_simulador:correr()` surtió **20/20 O− exactas**; en el pico reservó **50/50** (40 A+ exactas, 10 A− compatibles), despachó 30 y liberó 20 no usadas. Estado final de **esa corrida de referencia, no del panel público en vivo**: 207 disponibles, 50 asignadas, 1 retirada y 42 comprometidas, con `invariantes=ok`.

La corrida aislada de `p44_caos:correr()` sometió el sistema a solicitudes bajo carga y mató: **una unidad reservada, un refrigerador fallado, el proceso de alertas, el inventario, el supervisor de unidades y la bitácora**. Los **seis experimentos** dieron `ok=true`, `invariantes=ok` y 300 unidades recuperadas antes/después de la caída de la bitácora. Durante la carga se observaron 29 solicitudes surtidas y 0 interrumpidas; esto **no demuestra** que nunca haya interrupciones justo en el instante de la falla. En el [README se explican «qué se mató / qué se esperaba / qué ocurrió» y las limitaciones](https://github.com/Apu3114/erlang-proyectos/blob/main/proyectos/44-banco-de-sangre/README.md#prueba-de-caos). Las pruebas destructivas se ejecutaron **fuera de la demo pública**.

### 1.4 Investigación y aplicación del diseño UI/UX

Se preparó el [prompt para Google Stitch](https://github.com/Apu3114/erlang-proyectos/blob/main/proyectos/44-banco-de-sangre/design/PROMPT_STITCH.md), que pidió tablero principal, detalle de una unidad y bitácora, en español, legibles en móvil y con colores para estados. Se exportaron [maquetas y capturas de Dashboard, Detalle y Bitácora](https://github.com/Apu3114/erlang-proyectos/blob/main/proyectos/44-banco-de-sangre/design/DESIGN.md). **Esas pantallas son maquetas:** parte de su vocabulario clínico no existe en el backend real; `design/DESIGN.md` documenta las diferencias. La app funcional `design/app/index.html` se conectó a API reales y añadió navegación, formularios, búsquedas y alertas SSE. El logo `design/app/logo.svg` es una ilustración original hecha para esta interfaz, no un recurso externo. Las capturas de Stitch **no sustituyen** las capturas pendientes de la web funcional.

**Fuentes consultadas/documentadas (para revisión del profesor):** [enunciado](https://github.com/Apu3114/erlang-proyectos/blob/main/proyectos/44-banco-de-sangre/problema/readme.md); [NOM-253-SSA1-2012 en el DOF](https://www.dof.gob.mx/nota_detalle.php?codigo=5275587&fecha=26/10/2012); [tabla de cifras, fuentes y supuestos en README](https://github.com/Apu3114/erlang-proyectos/blob/main/proyectos/44-banco-de-sangre/README.md#cifras-del-enunciado-verificaci%C3%B3n); [prompt y evidencia visual de Stitch](https://github.com/Apu3114/erlang-proyectos/blob/main/proyectos/44-banco-de-sangre/design/DESIGN.md); [código de reglas de compatibilidad](https://github.com/Apu3114/erlang-proyectos/blob/main/proyectos/44-banco-de-sangre/src/p44_compatibilidad.erl). La tabla anterior distingue explícitamente lo contrastado con la NOM de las cifras **inventadas para la simulación** y de las reglas simplificadas que aún requerirían investigación clínica adicional.

---

## 2. Acceso y requisitos

### Desde el navegador (sin instalar nada)

1. Abrir un navegador moderno (Edge, Chrome, Firefox).
2. Ir a: `http://54.227.229.168/app/`
3. La página redirige/carga directamente en `/app/`.
4. Si el laboratorio AWS Academy está apagado o la IP cambió, la página no abrirá. Consultar la IP pública actual en la consola de AWS Academy.

### Desde la VM por SSH (para desarrollo o despliegue)

```powershell
# Desde PowerShell en Windows
ssh -i "C:\RUTA\DE\TU\CLAVE\aws_academy_p44" ubuntu@54.227.229.168
```

Una vez dentro:

```bash
cd /home/ubuntu/erlang-proyectos/proyectos/44-banco-de-sangre
sudo systemctl is-active p44-banco-de-sangre nginx
```

---

## 3. Vista general de la aplicación

La página usa un solo archivo HTML con CSS embebido y JavaScript vanilla. No depende de frameworks externos.

### Elementos globales

| Elemento | Descripción |
|----------|-------------|
| **Logo** | SVG original en la esquina superior izquierda. Gota de sangre con cruz médica blanca. También usado como favicon. |
| **Cabecera** | Fondo blanco con sombra sutil, contiene el logo, el nombre "Banco de sangre" y un indicador de estado en tiempo real. |
| **Estado del sistema** | Píldora en la cabecera: texto "● Sistema en línea" o "● Sin conexión" según respondan las consultas. |
| **Navegación** | Barra de pestañas: Inventario, Lotes, Donantes, Procesos, Bitácora. Cambia de vista mediante `location.hash` sin recargar. |
| **Actualización automática** | Los datos se refrescan cada 15 segundos vía `fetch` a los endpoints de la API. |
| **Alertas en tiempo real** | Conexión SSE (`EventSource`) a `/api/alertas` que muestra avisos emergentes cuando hay niveles críticos. |
| **Pie de página** | Advertencia de uso académico y que el laboratorio AWS debe permanecer encendido. |

### Colores principales

- **Rojo sangre principal:** `#801b2d` (botones activos, encabezados, acentos).
- **Rojo oscuro:** `#681526` (hover de botones primarios).
- **Fondo general:** `#f5f6f8` (gris muy claro).
- **Paneles:** blanco con borde `#e5e9ee` y sombra suave.
- **Éxito/ disponible:** verdes suaves.
- **Peligro/crítico:** rojos suaves.

---

## 4. Detalle por sección

### 4.1 Inventario (`#inventario`)

Vista principal al cargar.

**Tarjetas de estado (estadísticas):**
- Disponibles
- Reservadas
- Despachadas
- Próximas a caducar (48 h)

**Formulario de reserva:**
- Tipo del receptor (8 tipos ABO/Rh)
- Componente (Glóbulos rojos, Plasma, Plaquetas)
- Solicitante (texto ficticio, máx. 100 caracteres)
- Reserva en minutos (TTL, 1–1440)

Al reservar, el sistema busca:
1. Tipo exacto disponible.
2. Si no hay, tipos compatibles ordenados por versatilidad (conserva O negativo cuando sea posible).
3. Dentro del tipo, aplica FEFO (la que primero vence sale primero).

**Existencias disponibles:**
Grid de tarjetas por combinación tipo + componente (ej. `O+ · Glóbulos rojos`). Si hay ≤ 5 unidades, se marca como crítica.

> Ejemplo de uso seguro: consultar existencias sin enviar el formulario, solo para observar.

---

### 4.2 Lotes (`#lotes`)

Permite ver, crear y gestionar lotes de sangre.

**Filtro:** "Solo lotes con unidades disponibles" (marcado por defecto). Al desactivarlo se ven también los lotes vacíos.

**Tarjetas de lote:** muestran nombre, número de lote, componente, estado del refrigerador, total de unidades y disponibles.

**Detalle del lote seleccionado:**
- Nombre y estado del refrigerador (`operando` / `fallado` / `desconocido`)
- Resumen de estados (cuántas disponibles, reservadas, asignadas, retiradas, comprometidas, caducadas)
- Existencias utilizables por tipo y componente
- Tabla de unidades del lote con botón "Ver proceso" para cada una

**Formulario "Crear un lote":**
- Nombre del lote (máx. 80 caracteres)
- Componente (rojos, plasma, plaquetas)
- Al crear, el lote empieza vacío. Luego se puede añadir una unidad de un donante registrado.

**Panel "Añadir una unidad al lote":**
- Solo se muestra si el lote seleccionado está `operando`.
- Desplegable de donantes registrados elegibles para esa alta (excluye donantes bloqueados y duplicados de mismo donante/componente en ese lote).
- La caducidad se calcula automáticamente: rojos 42 días, plasma 365 días, plaquetas 7 días.

**Simular falla de refrigerador:**
- Desplegable de todos los lotes.
- Botón "Simular falla" (peligro). Acción **irreversible** en la demo pública. Compromete todas las unidades del lote seleccionado.
- Requiere confirmación explícita.

---

### 4.3 Donantes (`#donantes`)

Muestra las fichas de donantes y permite registrar nuevos (ficticios).

**Nota importante:** los donantes originales de la simulación no tenían edad ni peso registrados. La ficha muestra "No registrado" en esos campos. No se inventan datos personales.

**Filtros:**
- Buscar por ID o alias
- Filtrar por tipo sanguíneo (O−, O+, A−, A+, B−, B+, AB−, AB+)

**Lista de donantes:** tarjetas con ID, alias, tipo, total de unidades, disponibles y etiqueta "BLOQUEADO" si aplica.

**Ficha del donante seleccionado:**
- Alias, ID, tipo sanguíneo
- Edad simulada (o "No registrado")
- Peso simulado en kg (o "No registrado")
- Fecha de alta (o "No registrada")
- Total de unidades y disponibles
- Advertencia: "La edad y el peso de los donantes originales no se registraron. No se verifica aptitud médica ni el intervalo entre donaciones."
- Botón "Retirar unidades de este donante" (abre el panel de retiro)

**Formulario "Registrar donante ficticio":**
- Alias ficticio (máx. 80 caracteres, requerido)
- Tipo sanguíneo
- Edad simulada opcional (18–65)
- Peso simulado en kg opcional (50–250)
- Advertencia: no usar nombres, teléfonos ni datos médicos reales. No certifica aptitud para donar.

**Panel "Retiro por prueba positiva tardía":**
- ID del donante (requerido)
- Motivo (máx. 200 caracteres, requerido)
- Acción irreversible sobre la demo. Retira unidades disponibles del donante y reporta las ya despachadas con su receptor para seguimiento. El donante queda bloqueado para nuevas unidades.

---

### 4.4 Procesos (`#procesos`)

Lista de unidades con sus estados actuales.

**Filtros:**
- Buscar por ID de unidad o ID de donante
- Estado (todos, disponible, reservada, asignada, retirada, comprometida, caducada)
- Componente (todos, glóbulos rojos, plasma, plaquetas)

**Cada fila muestra:**
- Número de unidad, tipo y componente
- Donante, lote, fecha de caducidad
- Solicitante y receptor (si aplica)
- Badge con el estado actual
- Acciones según el estado:
  - Si está `reservada`: "Despachar" (pide receptor ficticio) y "Liberar"
  - Si está `disponible` o `reservada`: "Retirar" (pide motivo)
  - Siempre: "Historial" (abre la bitácora filtrada por esa unidad)

> Máximo 100 unidades mostradas por vista para rendimiento.

---

### 4.5 Bitácora (`#bitacora`)

Trazabilidad de eventos del sistema.

**Filtro opcional:** ID de unidad (para ver solo los eventos de una unidad específica).

**Cada evento muestra:**
- Fecha y hora (formato es-MX)
- Unidad afectada y evento/estado
- Descripción del evento

Últimos 100 eventos. Se actualiza automáticamente cada 15 segundos si se está en esta pestaña.

---

## 5. API HTTP y métricas

El backend Cowboy expone los siguientes endpoints (todos bajo `/api/` o `/metrics`):

| Ruta | Método | Qué hace |
|------|--------|----------|
| `/api/inventario` | GET | Existencias por tipo y componente |
| `/api/solicitudes` | POST | Reserva una unidad (cuerpo JSON con receptor, componente, solicitante, ttl_ms) |
| `/api/alertas` | GET | Stream SSE con alertas críticas |
| `/metrics` | GET | Unidades por estado, próximas a caducar en 48 h, histórico de asignadas |
| `/api/unidades` y `/api/unidades/:id` | GET | Listar unidades y detalle actual de una unidad |
| `/api/unidades/:id/acciones` | POST | Despachar, liberar o retirar una unidad |
| `/api/bitacora?unidad=ID` | GET | Últimos 100 eventos (opcionalmente filtrados por unidad) |
| `/api/refrigeradores/:id/falla` | POST | Simular falla de un lote/refrigerador |
| `/api/donantes` y `/api/donantes/:id` | GET | Fichas de donantes y unidades vinculadas |
| `/api/donantes` | POST | Registrar donante ficticio |
| `/api/donantes/:id/retirar` | POST | Retirar unidades por prueba positiva tardía |
| `/api/lotes` y `/api/lotes/:id` | GET | Lotes con estado y existencias (incluidos vacíos) |
| `/api/lotes` | POST | Crear lote vacío para un componente |
| `/api/lotes/:id/unidades` | POST | Añadir una unidad de donante existente al lote |

Todos los handlers validan entrada con lista blanca y responden JSON con códigos 200/201/400/404/405/409/503.

---

## 6. Sección de capturas (para la entrega)

El estudiante debe tomar capturas de pantalla desde su navegador y pegarlas aquí o en su entrega. Ejemplo de tabla para organizar:

| Pantalla | Qué mostrar | Archivo de captura |
|----------|-------------|--------------------|
| Cabecera + Logo | Logo en esquina, nombre, estado en línea | `captura-logo.png` |
| Inventario | Tarjetas de estado, existencias, formulario de reserva | `captura-inventario.png` |
| Lotes | Lista de lotes, detalle de uno, formulario crear lote | `captura-lotes.png` |
| Donantes | Lista de donantes, ficha de uno, formulario registrar | `captura-donantes.png` |
| Procesos | Lista de unidades, filtros, acciones | `captura-procesos.png` |
| Bitácora | Eventos recientes, filtro por unidad | `captura-bitacora.png` |
| Pruebas | Terminal con `rebar3 eunit` (76 pruebas, 0 fallos) | `captura-pruebas.png` |
| Simulación | Terminal con `p44_simulador:correr()` y resultados | `captura-simulacion.png` |
| Caos | Terminal con `p44_caos:correr()` y 6 experimentos ok | `captura-caos.png` |

> **Instrucción:** abre la app en `http://54.227.229.168/app/`, navega por cada pestaña y presiona `Pant Pant` o `Win + Shift + S` (Windows) para capturar. No incluyas credenciales, IPs privadas ni datos reales.

### Video de demostración en Loom

**Enlace del video:** **[PEGA AQUÍ TU ENLACE DE LOOM]**

El autor indicó que ya tiene el video. Antes de entregar, reemplaza el texto entre corchetes por la URL completa de Loom y comprueba en una ventana privada del navegador que el profesor pueda verlo. No incluyas claves ni datos personales en la grabación.

> El checklist fue marcado por el autor en el Gist. Si el video se entregó por otra vía, conserva esa evidencia; el marcador anterior **todavía no es un enlace** y debe reemplazarse si este Gist será la referencia para el profesor.

---

## 7. Prompts usados con OpenCode durante el desarrollo

A continuación aparecen **fragmentos de instrucciones que constan en los archivos del proyecto y mensajes conservados de la conversación**. No son una transcripción íntegra de toda la sesión. Se diferencia el texto de usuario de decisiones detectadas por el asistente; no se presentan resúmenes inventados como citas literales.

### Prompt de contexto para OpenCode (archivo del repositorio)

El proyecto incluye [`PROMPT_OPENCODE.md`](https://github.com/Apu3114/erlang-proyectos/blob/main/proyectos/44-banco-de-sangre/PROMPT_OPENCODE.md), una guía de continuidad de desarrollo. Parte de un estado **anterior** de 31 pruebas y describe la arquitectura inicial; **no debe confundirse con el estado final de 76 pruebas**, ni copiar sus instrucciones antiguas de credenciales como procedimiento actual. Un fragmento representativo:

> «Cada unidad de sangre es un proceso (`gen_statem`), dueño exclusivo de su propio estado.»

También se usó [`design/PROMPT_STITCH.md`](https://github.com/Apu3114/erlang-proyectos/blob/main/proyectos/44-banco-de-sangre/design/PROMPT_STITCH.md) para pedir a Google Stitch un dashboard, detalle de unidad y bitácora legibles en celular; sus capturas y limitaciones se documentan en [`design/DESIGN.md`](https://github.com/Apu3114/erlang-proyectos/blob/main/proyectos/44-banco-de-sangre/design/DESIGN.md).

### Solicitud del usuario: mejoras visuales y logo
> «mira si pues hacerla mucho mas profesional y realizar un logo para la pagina y que este en la esquina te lo agradeceria muhco»

Se creó `design/app/logo.svg` (gotas de sangre con cruz médica blanca, sin imágenes externas) y se reescribió el CSS de `design/app/index.html` para usar:
- Estilos base en CSS (`:root`)
- Cabecera con logo SVG enlazado y estado
- Tarjetas, paneles, botones y formularios con bordes redondeados y sombras
- Diseño responsivo con `@media` para móvil y escritorio

### Solicitud del usuario: donantes y lotes
> «pienso que falta mas sobre los donantes ya registrados y demas los datros de el, y en el de lotes falta lo que es la crecion de ellos hazlo mas completo»

Este fragmento refleja la petición registrada; se respetó la ausencia de datos personales originales y se hicieron altas con información ficticia.

Se añadieron:
- `src/p44_catalogo.erl` (altas serializadas de donantes, lotes y unidades)
- `src/p44_http_catalogo_donantes_handler.erl`
- `src/p44_http_lotes_handler.erl`
- `src/p44_http_lote_unidades_handler.erl`
- Sección Donantes en el HTML con búsqueda, filtros, registro ficticio y retiro
- Sección Lotes mejorada con crear lote vacío, añadir unidad y simular falla

### Corrección de persistencia DETS (hallazgo técnico, no prompt del usuario)

Al verificar reinicios de la VM apareció un fallo de recuperación; se investigó el historial y se corrigió. **No fue una petición textual del estudiante.**

Se corrigieron `src/p44_bitacora.erl`, `src/p44_unidad.erl` y `src/p44_refrigerador.erl` para que:
- Cada registro DETS tenga clave única entre reinicios (nanosegundos + bytes aleatorios)
- El historial se ordene por fecha
- Las unidades y refrigeradores busquen explícitamente su evento de creación

### Solicitud del usuario: ejecutar todas las simulaciones
> «no te quiero interrumpir pero eso son los criterios de lo que me pide tambinen igual haztodas las simulcaciones que venian en el repo y todo»

Se ejecutaron y verificaron:
- `p44_simulador:correr()` → accidente O−, pico de cirugías A+, retiro por donante, falla de refrigerador
- `p44_caos:correr()` → 6 experimentos (unidad, refrigerador, alertas, inventario, supervisor, bitácora)
- Invariantes de ambas corridas → `ok`

### Documentación y entrega
> "mira ya comparti ese gist para la entrega de mi proyecto, ese no lo borres ni lo modifiques pero ahora ocupo que hagas otro que explique todo lo dela pagina a detalle..."

Se creó este documento y un **segundo Gist**. El [primer Gist de entrega](https://gist.github.com/Apu3114/899f079a374af6fe8f5e473c40a66420) permanece separado y no se modifica aquí. En una petición posterior se solicitó ampliar este segundo Gist con introducción e investigaciones; este apartado y la sección 1 responden a esa petición.

---

## 8. Tecnologías y arquitectura

### Backend (Erlang/OTP)
- **Lenguaje:** Erlang/OTP 26.2.5 (compilado con kerl en la VM)
- **Build tool:** rebar3 3.28.0
- **Servidor HTTP:** Cowboy (sin dependencias externas de JSON; se usa `p44_json` propio)
- **Modelo de procesos:** Una unidad de sangre = un proceso `gen_statem`
- **Supervisión:** `p44_banco_de_sangre_sup` con estrategia `rest_for_one`
- **Persistencia:** ETS (rápido, en memoria) + DETS (disco, sobrevive a reinicios)
- **Supervisores dinámicos:** `p44_unidades_sup` y `p44_refrigeradores_sup` (estrategia `simple_one_for_one`)
- **Repoblador:** recrea unidades y refrigeradores desde DETS tras caídas
- **Grupos de procesos:** `pg` para localizar unidades por lote y donante sin recorrer las 300

### Frontend
- HTML5, CSS3, JavaScript vanilla (ES6+)
- Diseño responsivo (grid, flexbox, media queries)
- Fetch API para REST
- EventSource para SSE (alertas en tiempo real)
- Archivo SVG independiente para el logo, usado también como favicon

### Despliegue
- VM Ubuntu en AWS Academy
- systemd servicio `p44-banco-de-sangre`
- nginx proxy inverso HTTP/80
- IP pública puede cambiar al reiniciar el laboratorio

---

## 9. Advertencias y limitaciones

1. **Datos ficticios:** la web es pública y no tiene autenticación. No introducir nombres reales, teléfonos, datos médicos ni credenciales.
2. **Sin TLS:** la conexión es HTTP, no HTTPS.
3. **Demo pública compartida:** cualquier persona con la URL puede leer y modificar el inventario simulado. Para pruebas destructivas (fallas, retiros, reinicios), usar una copia aislada del proyecto.
4. **`p44_simulador:reiniciar/0` borra la bitácora:** nunca ejecutar en la VM pública.
5. **Punto único de falla:** el archivo DETS (`_build/prod/rel/p44_banco_de_sangre/priv/p44_bitacora.dets`) no está replicado. Respaldarlo antes de reconstruir el release.
6. **IP cambiante:** la IP de AWS Academy puede cambiar. Verificar antes de presentar.
7. **Compatibilidad simplificada:** plasma y plaquetas usan una regla simplificada (ABO invertido, Rh ignorado). No sustituye reglas clínicas reales.
8. **Intervalo entre donaciones:** no se modela en el código (aunque la NOM-253-SSA1-2012 lo establece). No se verifica aptitud médica.

---

## 10. Checklist de entrega

- [x] Video de Loom preparado (según indica el autor; enlace aún no añadido aquí)
- [x] Enlace de Loom pegado en el apartado anterior y acceso verificado (marcado por el autor; comprobar el marcador visible arriba)
- [x] Capturas de la app real tomadas (inventario, lotes, donantes, procesos, bitácora; marcado por el autor)
- [ ] Capturas de pruebas (`rebar3 eunit`: 76 pruebas, 0 fallos)
- [ ] Capturas de simulación y caos (invariantes = ok)
- [x] Gist publicado con este manual (Loom y capturas aún por enlazar)
- [x] Código subido a `https://github.com/Apu3114/erlang-proyectos` rama `main`
- [ ] App pública verificada en `http://54.227.229.168/app/`
- [ ] No se incluyeron claves privadas ni datos reales en ninguna entrega

---

*Documento generado como parte de la entrega del proyecto #44 Banco de sangre. Última actualización: 11 de noviembre de 2026.*
