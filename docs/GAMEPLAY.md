# Tiny Realtor: cómo se juega

*Primer bucle de juego. Corto y concreto; los números exactos viven en `scripts/economy.gd` y
`tools/econ_sim.gd` los juega. Si algo choca con `DESIGN.md`, manda este documento en lo que es
juego (dinero, compras, obras, banco, gerentes). Revisado tras dos revisiones de diseño (juego en
una esquina y economía) y dos de código.*

## 1. Para qué tipo de juego es

Una ventanita de 600x600 (o más pequeña, hasta 200 px) siempre encima, en una esquina, mientras
trabajas. Casi siempre está abierta pero nadie la mira. Por eso:

- **Se entiende de un vistazo**: arriba a la derecha tu dinero y cuánto ganas por minuto; abajo
  la **siguiente jugada** y la barra de la oficina; en el mapa, flechitas doradas donde puedes
  construir ya y etiquetas de precio doradas en lo que puedes comprar ya.
- **Pocos clics que importan**: cada visita son 2-6 clics. Nada que hacer cada segundo.
- **Gana sola**: el alquiler entra por minuto, también con el juego cerrado (con tope).
- **Nunca castiga por no mirar**: las obras acaban solas, el banco nunca te ahoga, el constructor
  de la oficina sigue construyendo sin ti, una noche entera se cobra (12 h desde el principio).
- **Tranquila**: los "+$" sobre los tejados solo salen con el ratón encima de la ventana; nada
  parpadea mientras trabajas.
- **Se ve crecer**: cada obra cambia el dibujo del barrio.
- **Un clic sin querer no cuesta**: comprar y construir se pueden deshacer durante 6 s;
  contratar un gerente pide un segundo toque.

## 2. El bucle

1. **Cobras** el alquiler de lo tuyo cada minuto.
2. **Compras** terrenos dentro del radio de tu oficina: un **solar** es barato; uno **ya
   construido** es caro pero paga desde el primer minuto. Siempre hay al menos 3 solares cerca
   de una oficina nueva.
3. **Construyes**: Solar → Casas → Urbanización → Bloque de pisos → Torres → Rascacielos. Se paga
   al empezar, tarda (de 20 s a 3 h por nivel), se ve una obra con valla, andamios y grúa, y al
   acabar paga más. Puedes subir **varios niveles de golpe** ("HASTA TORRES": la suma del coste y
   del tiempo). Cada obra ocupa una **grúa**.
4. **Subes la oficina** (en su pestaña): el radio crece (150 → 225 → 300 → 400 → 500 m),
   aparecen más terrenos, suben sus **comisiones**, más grúas y más horas sin conexión. En el
   **Nv 2** llega tu primer **gerente, gratis**. En el **Nv 3** se abre el **constructor
   automático** (OBRAS SOLAS).
5. Con una oficina en Nv 3 puedes **abrir otra** en otro sitio, que empieza su propia escalera.
6. Más adelante: salir a bolsa, recalificaciones, eventos (punto 11).

## 3. Los terrenos

- Un terreno vale por su **tamaño** (factor de área 0,35-1,6, crece más despacio que los m²) y
  por **su sitio**, de los datos reales: Parque cerca **+20 %**, Avenida **+15 %**, Vistas al
  agua **+25 %**, Zona comercial **+15 %**, Junto a las vías **−15 %**. (La esquina se quitó: el
  90 % de los terrenos lo son.) Estos extras suben todo el alquiler y el precio solo a medias:
  los buenos sitios rinden más.
- **Lo que cabe**: industrial hasta naves (Urbanización); < 1.500 m² hasta Bloque; < 3.000 m²
  hasta Torres; los grandes hasta Rascacielos.
- **Plusvalía**: cada terreno que tienes en una oficina encarece un 4 % los demás de esa oficina,
  y cada nivel de obra terminado encarece un 1 % las siguientes obras de esa oficina. Así los
  primeros minutos son baratos y el final dura días.

## 4. Números (factor de área 1)

| Nivel | Construir (desde el anterior) | Tiempo | Alquiler/min |
|---|---|---|---|
| Solar (comprar) | $20K | – | 0 |
| Casas | $15K | 20 s | $10K |
| Urbanización | $150K | 2 min | $35K |
| Bloque de pisos | $2M | 10 min | $120K |
| Torres | $40M | 45 min | $400K |
| Rascacielos | $800M | 3 h | $1,4M |

Un terreno ya construido cuesta su solar + sus obras x 1,25 (pagas por no esperar).

| Oficina | Radio | Subir al siguiente | Comisiones de la oficina | Grúas | Cobro sin conexión |
|---|---|---|---|---|---|
| Nv 1 | 150 m | $60K | $2K/min | 1 | 12 h |
| Nv 2 | 225 m | $15M | $12K/min | 2 | 14 h |
| Nv 3 | 300 m | $8MM | $60K/min | 2 | 16 h |
| Nv 4 | 400 m | $250MM | $300K/min | 3 | 20 h |
| Nv 5 | 500 m | – | $1,5M/min | 3 | 24 h |

- Empiezas con **$35K** y el terreno donde pones la oficina, gratis, como **solar**: tu primera
  obra puede ser ahí mismo. (Antes eran $50K y el terreno venía con bloques que no se podían
  tocar; con el solar gratis se empieza un poco más rico, así que el dinero inicial baja.)
- Segunda oficina $3MM, tercera $300MM, cuarta $10B (con una oficina en Nv 3).
- Dinero en formato español: `$12.345`, `$123,4K`, `$1,23M`, `$45,6MM` (mil millones), `$7,1B`
  (billón = un millón de millones).

## 5. Tu oficina

- **La oficina no es un edificio**: es tu negocio, y vive en una **pestaña** (pantalla completa,
  como el banco). No ocupa sitio en el barrio, así que todo el suelo es para construir.
- En el mapa solo queda **un punto**: una **chincheta dorada** con la casita del mapa de la
  ciudad y un anillo dorado pintado en el suelo, en la acera o la esquina libre más cercana a
  donde pulsaste (en el centro del anillo del radio). No estorba a ningún terreno. Al pasar el
  ratón dice **TU OFICINA**; al pulsarla se abre la pestaña.
- El terreno donde pusiste la oficina es **tuyo desde el principio, gratis, como solar**: un
  terreno normal, con sus reglas (lo que cabe según tamaño y zona), que puedes llevar hasta
  rascacielos.
- La oficina gana sus propias **comisiones** por minuto, que suben con su nivel ($2K → $12K →
  $60K → $300K → $1,5M); el gerente las sube igual que los alquileres. Son el antiguo "alquiler
  de tu oficina".
- **La pestaña de la oficina** (el **maletín** a la derecha, la barra de nivel de abajo, la
  siguiente jugada "Sube la oficina" o la chincheta) tiene dos páginas:
  - **OFICINA**: nivel y radio; lo que ganas (alquileres + comisiones); terrenos, obras y grúas
    libres; horas de cobro sin conexión; **SUBIR A NV X** con lo que trae el siguiente nivel
    (radio, comisiones, grúas, horas sin conexión, gerente gratis, obras solas, abrir otra
    oficina) y lo que falta; el interruptor **OBRAS SOLAS** (desde Nv 3: con una grúa libre
    empieza sola la obra que antes se paga, sin gastar más de la mitad del dinero, también sin
    conexión); y filas grises **PRONTO** (salir a bolsa, recalificar) para lo que vendrá.
  - **GERENTE**: el que manda, los candidatos de la agencia, OTROS y contratar (punto 7).
- Un punto claro en el maletín avisa de que hay algo que hacer dentro (puedes subir de nivel, o
  no tienes gerente y puedes contratar uno).
- **Partidas de antes**: al cargar, el terreno de la oficina (que eran bloques fijos) pasa a ser
  un solar tuyo; lo que ganabas no cambia (su alquiler era el de la oficina, que ahora son las
  comisiones) y un aviso dice "El solar de tu oficina queda libre".

## 6. El banco

Para ir más rápido, nunca para hundirte. Reglas fijas de Oscar:

- **Tres préstamos**, uno de cada a la vez:

  | Tipo | Comisión | Interés | Máximo |
  |---|---|---|---|
  | Rápido | 1 % | 3 %/h | 30 min de alquiler |
  | Normal | 3 % | 1,2 %/h | 3 h de alquiler |
  | Hipoteca | 5 % | 0,35 %/h | 15 h de alquiler, y no más del 50 % de lo que valen tus terrenos (el de tu oficina cuenta como cualquier otro); la fila lo dice cuando eso es lo que la limita |

- **Nunca te ahoga**:
  - El interés se suma a la deuda; **nunca sale de tu caja**. Tu dinero solo puede subir.
  - Todo el interés junto se corta al **8 % de tu alquiler de ese momento**: aunque pierdas
    ingresos (despides al gerente), el interés nunca llega a lo que ganas.
  - No te dejan pedir si con ese préstamo el interés de todos pasaría del **6 % de tu alquiler**.
  - Una deuda deja de crecer al llegar a **1,5 veces** lo prestado.
  - El interés corre sin conexión solo durante las horas que también cobras alquiler.
  - Nunca te quitan terrenos. No hay bancarrota ni fin de partida.
- **Pago automático**: NO / 10 % / 25 % / 50 % de cada alquiler va a la deuda (también sin
  conexión), primero al préstamo más caro. Por defecto 10 %. Como el interés nunca pasa del 8 %,
  con cualquier pago automático la deuda total **siempre baja**.
- **Antes de firmar** se ve: lo que recibes, lo que debes (con comisión), el **interés por minuto
  al lado de tu alquiler por minuto**, y en cuánto se paga sola con el 10, 25 y 50 %.
- En la ficha de un terreno, si te falta dinero y el banco te deja, sale **PRESTAR $X**: pide
  justo lo que falta (del préstamo más barato con sitio) y compra o construye en el mismo toque.
- **Devolver** paga de golpe lo que puedas de ese préstamo.
- No se puede "farmear": la comisión se paga al pedir, así que pedir y devolver solo pierde
  dinero; el límite sale de tu alquiler, no de tu caja.
- La simulación y `game_check` lo comprueban: quien pide lo máximo, pierde su gerente y se va una
  semana sigue ganando dinero, su interés nunca pasa del 8 % y con pago automático la deuda baja.

## 7. Gerentes

- Desde la **oficina Nv 2** cada oficina tiene **un gerente** (retrato pixel art y nombre:
  "Lola Ferrer"), en la página **GERENTE** de la pestaña de la oficina. El primero llega
  **gratis** al subir a Nv 2 (común, +10 % alquiler y comisiones).
- **Agencia**: 3 candidatos por oficina; cada 6 h salen otros. "OTROS" los cambia ya, por 10 min
  de tu alquiler (el doble cada vez dentro de las mismas 6 h). Los candidatos se guardan: no
  cambian al subir de nivel ni moviendo el reloj.
- **Precio**: según su rareza, en minutos de tu alquiler total (común 30, rara 90, épica 300,
  legendaria 900; con un mínimo por nivel de oficina). Así un gerente nunca es una ganga para
  siempre. El nuevo sustituye al anterior (segundo toque para confirmar).
- **Rarezas**: Común (1 bonus), Rara (1 mejor), Épica (2), Legendaria (2 + **Capataz**: +1 grúa).
  Cuanto más nivel tiene la oficina, más salen raras.
- **Bonus** (común → legendaria): alquiler +10/20/30/45 %, obras −10/15/25/35 % de coste,
  obras −15/25/40/50 % de tiempo, compras −10/15/25/35 %, +2/4/8/12 h sin conexión, **Banquero**
  −15/25/40/60 % de interés y +50 % de préstamo.
- No suben de nivel: se mejora contratando uno mejor (sencillo, de un vistazo).
- Retratos: 16x16 píxeles hechos con matemáticas (piel, pelo, ojos, gafas, bigote, traje y
  corbata o blusa), solo colores de la paleta, con borde de tinta, dibujados x2, x4 o x6 en un
  marco del color de su rareza (gris, cian, menta, oro).

## 8. Sin conexión y la partida

- Al volver: "**Mientras no estabas: +$X**" (tiempo fuera y cobrado, obras acabadas, lo pagado
  al banco). Cualquier toque lo cierra.
- Una pausa de más de 2 minutos con el juego abierto (ordenador dormido) cuenta como fuera.
- Reloj hacia atrás: el juego sigue con su propio cronómetro y nunca cobra dos veces lo mismo;
  un reloj adelantado solo gasta tu propio cobro sin conexión (con su tope).
- **Se guarda** en `user://save.json` (los datos de prueba en `save_fixture.json`): dinero,
  banco, y por oficina su nivel, terrenos, obras con su hora de fin, constructor y gerente. Al
  cambiar algo, cada 30 s y al cerrar. Una partida rota empieza de nuevo sin colgarse.
- El juego se abre directamente en la última oficina vista.

## 9. Pantalla

- **Oficina**: arriba izquierda volver + barrio y "N / M tuyos"; arriba derecha **dinero**,
  **+X/min** (menta) y la deuda (roja) si la hay. A la derecha: zoom + −, **banco** ($) y
  **oficina** (maletín). Abajo: la **siguiente jugada** ("> COMPRA UN SOLAR EN CARRER D'ARAGÓ ·
  $30.903", o el tiempo que falta; tocarla te lleva) y la línea de la oficina: "NV 1 · GRÚAS 1/1"
  y "NV 2: FALTAN $9.913 · ~5 MIN" o "¡SUBIR A NV 2!"; tocarla abre la pestaña de la oficina.
- **Mapa**: precio sobre los terrenos en venta (dorado si puedes pagarlo), flecha dorada donde
  puedes construir, barra y tiempo sobre cada obra, "+$" sobre tus tejados.
- **Ficha de un terreno**: calle, zona, lo que hay, m², extras del sitio, alquiler (en un solar,
  lo que pagaría con casas); un botón grande (COMPRAR $X / CONSTRUIR CASAS · $X / EN OBRAS 3:20 /
  AL MÁXIMO) y otro al lado (HASTA TORRES / PRESTAR $X), con la razón en gris debajo (te faltan
  $X · ~4 min, sube la oficina para llegar, grúas ocupadas, tarda 2 min).
- **Banco** y **Tu oficina** (con sus páginas OFICINA y GERENTE): pantallas completas con volver
  y título, como todas.
- Todo lo que se pulsa mide al menos 44 px de lienzo.

## 10. Lo que dice la simulación (Valencia, el Botànic; 130 terrenos)

`godot --headless --path . --script res://tools/econ_sim.gd -- --file=<oficina.json> --days=28`

| Hito | Ideal (siempre mirando) | Widget (un vistazo por hora, 4 clics, AUTO) | Perezoso (3 veces al día, 6 clics, AUTO) |
|---|---|---|---|
| Primera compra | 0 s | 0 s | 0 s |
| Primera obra acabada | 21 s | 21 s | 21 s |
| Oficina Nv 2 + primer gerente | 4 min | 4 min | 4 min |
| Primera Urbanización | 11 min | 11 min | 11 min |
| Primer Bloque | 39 min | 1 h 22 min | 5 h |
| Oficina Nv 3 | 1 h 15 min | 4 h 10 min | 1 d |
| Primeras Torres | 3 h 1 min | 6 h 47 min | 1 d 12 h |
| Primer Rascacielos | 14 h 26 min | 22 h 32 min | 1 d 18 h |
| Oficina Nv 4 | 22 h 24 min | 1 d 10 h | 2 d 12 h |
| Oficina Nv 5 | 5 d 4 h | 5 d 5 h | 6 d |
| Todo el radio de 500 m tuyo | 5 d 7 h | 6 d 2 h | 9 d |
| Todo al máximo | 8 d 13 h | 8 d 13 h | 9 d 3 h |

(Los dos que juegan poco juegan los 10 primeros minutos como el ideal.) Desde que la oficina no
ocupa terreno (solar gratis, comisiones por nivel, $35K al empezar) la tabla apenas se mueve: el
Nv 2 llega en 4 min en vez de 6 y lo demás queda a menos de un 10 % de antes (en la zona de
prueba, Nv 2 en 5 min en vez de 7). Con préstamos usados con cabeza (pedir lo que falta para
algo que se paga en menos de 2 h, pago automático 25 %): Nv 2 en 5 min, Nv 3 en 56 min; paga al
banco $1,3M en total. Quien pide lo máximo el día 2 sin pagar, pierde el gerente y se va una
semana: esa semana gana igualmente $74,5MM, su interés no pasa del 6 % de su alquiler y paga al
banco $5,9MM (unas 2 h de alquiler); llega al Nv 5 a la vez que el que se fue una semana sin
préstamos. Después de ~9 días la oficina está completa: el siguiente objetivo es abrir otra (no
simulado todavía).

## 11. Más adelante (no está hecho)

- **Salir a bolsa** (prestigio): vender todo por acciones que dan +% permanente.
- **Recalificar** un terreno para pasar su límite (industrial → residencial).
- **Eventos de un clic**, discretos: un cliente con un bocadillo sobre un tejado (cobra 2 min de
  alquiler), una inspección, una oferta de compra.
- **Simular varias oficinas** en `econ_sim` y ajustar sus precios.
- **Día y noche** con ventanas encendidas.
