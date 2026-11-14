# Tiny Realtor: cómo se juega

*Primer bucle de juego. Corto y concreto; los números exactos viven en `scripts/economy.gd` y
`tools/econ_sim.gd` los juega. Si algo choca con `DESIGN.md`, manda este documento en lo que es
juego (dinero, compras, obras, banco, gerentes).*

## 1. Para qué tipo de juego es

Una ventanita de 600x600 (o más pequeña, hasta 200 px) siempre encima, en una esquina, mientras
trabajas. Casi siempre está abierta pero nadie la mira. Por eso:

- **Se entiende de un vistazo**: arriba a la derecha tu dinero y cuánto ganas por minuto; abajo
  la barra de la oficina con el siguiente objetivo; en el mapa, flechitas doradas donde puedes
  hacer algo ahora mismo.
- **Pocos clics que importan**: cada visita son 2-6 clics (comprar un terreno, mandar una obra,
  subir la oficina). Nada que hacer cada segundo.
- **Gana sola**: el alquiler entra por minuto, también con el juego cerrado (con tope).
- **Nunca castiga por no mirar**: las obras acaban solas, el banco nunca te ahoga, no hay nada
  que se estropee si te vas una semana.
- **Se ve crecer**: cada obra cambia el dibujo del barrio; el dinero sube con "+$" sobre tus
  tejados.

## 2. El bucle

1. **Cobras** el alquiler de lo tuyo cada minuto ("+$1,2K" sale de tus tejados).
2. **Compras** terrenos dentro del radio de tu oficina: un **solar** es barato; uno **ya
   construido** es caro pero paga desde el primer minuto.
3. **Construyes** en lo tuyo: Solar → Casas → Urbanización → Bloque de pisos → Torres →
   Rascacielos. Se paga al empezar, tarda (de 20 s a 3 h por nivel), se ve una obra con andamios
   y grúa, y al acabar el terreno paga más. Puedes subir **varios niveles de golpe** (un clic,
   la suma del coste y del tiempo).
4. **Subes la oficina** de nivel: el radio crece (150 → 225 → 300 → 400 → 500 m), aparecen más
   terrenos, tu oficina paga más, tienes más grúas y más horas de cobro sin conexión. No necesita
   internet.
5. Con una oficina en Nv 3 puedes **abrir otra** oficina en otro sitio (se descarga), que empieza
   su propia escalera.
6. Más adelante: **salir a bolsa** (prestigio), recalificaciones, eventos (ver 9).

## 3. Los terrenos

- Un terreno vale por su **tamaño** (factor de área: crece más despacio que los m², 0,35-1,6) y
  por **su sitio**, sacado de los datos reales:
  - Parque cerca **+20 %**, Avenida (calle principal) **+15 %**, Vistas al agua **+25 %**,
    Esquina **+5 %**, Zona comercial **+15 %**, Junto a las vías **−15 %**.
  - Estos extras suben el alquiler entero y el precio solo a medias: los buenos sitios rinden
    más, y eso es una decisión.
- **Lo que cabe**: industrial solo hasta naves (Urbanización); < 1.500 m² hasta Bloque;
  < 3.000 m² hasta Torres; los grandes hasta Rascacielos.
- **Plusvalía**: cada terreno que tienes en una oficina encarece un 4 % los demás de esa oficina.
  Cada nivel de obra terminado encarece un 1 % las siguientes obras de esa oficina. Así los
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

| Oficina | Radio | Subir al siguiente | Alquiler de tu oficina | Grúas | Cobro sin conexión |
|---|---|---|---|---|---|
| Nv 1 | 150 m | $120K | $2K/min | 1 | 8 h |
| Nv 2 | 225 m | $15M | $12K/min | 2 | 10 h |
| Nv 3 | 300 m | $8B | $60K/min | 2 | 12 h |
| Nv 4 | 400 m | $600B | $300K/min | 3 | 16 h |
| Nv 5 | 500 m | – | $1,5M/min | 3 | 24 h |

- Empiezas con **$50K** y tu terreno de la oficina (gratis).
- Segunda oficina $200M, tercera $50B, cuarta $5T (con una oficina en Nv 3).
- Dinero en formato español: `$12.345`, `$123,4K`, `$1,23M`, `$45,6B` (B = mil millones).

## 5. Tu oficina

- Donde pones la oficina está **tu primer terreno**, gratis. En él hay **un edificio de oficinas
  modesto** (tres plantas, escaparate cian, un cartelito REALTOR y una bandera) y el resto del
  terreno son bloques de pisos normales con tejado turquesa. Ya no es un edificio enorme.
- Ese terreno no se reconstruye: su alquiler sube con el nivel de la oficina.
- Pulsar tu oficina (o la barra de abajo) abre su ficha: nivel, radio, grúas, cobro sin conexión,
  gerente, y el botón **SUBIR A NV 2 · $120K**.

## 6. El banco

Para ir más rápido, nunca para hundirte. Reglas fijas (Oscar):

- **Tres préstamos**, uno de cada a la vez:

  | Tipo | Comisión | Interés | Máximo |
  |---|---|---|---|
  | Rápido | 1 % | 3 %/h | 30 min de alquiler |
  | Normal | 3 % | 1,2 %/h | 3 h de alquiler |
  | Hipoteca | 5 % | 0,5 %/h | 10 h de alquiler, y no más del 50 % de lo que valen tus terrenos |

- **Nunca te ahoga**:
  - El interés se suma a la deuda; **nunca sale de tu caja**. Tu dinero solo puede subir.
  - Todo el interés junto se corta al **8 % de tu alquiler de ese momento**: aunque pierdas
    ingresos (por ejemplo, despides a un gerente), el interés nunca alcanza lo que ganas.
  - No te dejan pedir si con ese préstamo el interés de todos pasaría del **6 % de tu alquiler**.
  - Una deuda deja de crecer al llegar a **1,5 veces** lo prestado.
  - El interés corre sin conexión solo durante las horas que también cobras alquiler.
  - Nunca te quitan terrenos. No hay bancarrota ni fin de partida.
- **Pago automático**: NO / 10 % / 25 % / 50 % de cada alquiler va a la deuda (también sin
  conexión), primero al préstamo más caro. Por defecto 10 %. Como el interés nunca pasa del 8 %,
  con cualquier pago automático la deuda **siempre baja**.
- Devolver a mano: "Devolver" paga lo que puedas de ese préstamo.
- Antes de firmar, la pantalla enseña: cuánto recibes, la deuda (con comisión), el **interés por
  minuto al lado de tu alquiler por minuto**, y en cuánto se paga con cada nivel de pago
  automático.
- No se puede "farmear": la comisión se paga al pedir, así que pedir y devolver solo pierde
  dinero; el límite sale de tu alquiler, no de tu caja.
- La simulación lo comprueba: un jugador que pide lo máximo, pierde su gerente y se va una semana
  sigue ganando dinero; y con pago automático su deuda baja.

## 7. Gerentes

- Desde la **oficina Nv 2**, cada oficina puede tener **un gerente** (personaje con retrato pixel
  art y nombre: "Lola Ferrer").
- **Agencia**: 3 candidatos por oficina; cada 6 h salen otros (o pagas para verlos ya). Contratar
  cuesta según su rareza y el nivel de la oficina. El nuevo sustituye al anterior.
- **Rarezas**: Común (1 bonus), Rara (1 bonus mejor), Épica (2 bonus), Legendaria (2 bonus + uno
  especial). Cuanto más nivel tiene la oficina, más salen raras.
- **Bonus** (común → legendaria): alquiler +10/20/30/45 %, obras −10/15/25/35 % de coste,
  obras −15/25/40/50 % de tiempo, compras −10/15/25/35 %, +2/4/8/12 h sin conexión, interés
  −15/25/40/60 %. Especiales (solo legendarias): **Capataz** (+1 grúa) y **Piloto automático**
  (cuando hay una grúa libre y dinero, empieza sola la obra más barata).
- No suben de nivel: se mejora contratando uno mejor (sencillo, de un vistazo).
- Retratos: 16x16 píxeles generados con matemáticas (piel, pelo, ojos, gafas, bigote, traje,
  corbata), solo colores de la paleta, dibujados x3 o x4.

## 8. Sin conexión y la partida

- Al volver: "**Mientras no estabas: +$X**" (con cuánto tiempo, obras acabadas y lo pagado al
  banco). El cobro tiene tope (8 h al principio, 24 h en Nv 5, más con gerente); las obras acaban
  igual.
- Una pausa de más de 2 minutos con el juego abierto (el ordenador dormido) cuenta como "sin
  conexión".
- Si el reloj va hacia atrás no se cobra nada hasta que vuelve a pasar la última hora vista.
- **Se guarda** en `user://save.json` (los datos de prueba en `save_fixture.json`): dinero, banco,
  y por oficina su nivel, terrenos, obras con su hora de fin y gerente. Al cambiar algo y cada
  30 s; al cerrar también.
- El juego se abre directamente en la última oficina vista.

## 9. Pantalla (de un vistazo)

- **Oficina**: arriba izquierda volver + barrio; arriba derecha **dinero** (moneda dorada) y
  **+X/min** (menta); debajo "N / M tuyos". Zoom - + a la derecha. Abajo: "NV 1 OFICINA" y la
  barra hacia el siguiente nivel ("$60K / $120K"); cuando llega, la barra parpadea y pone
  "¡SUBIR!". Dos botones abajo: **BANCO** y **GERENTE**.
- Sobre el mapa: precio en dorado sobre los terrenos en venta que puedes pagar (gris si no);
  flecha dorada sobre lo tuyo que puedes mejorar; barra de progreso y tiempo sobre cada obra;
  "+$" con cantidad sobre tus tejados.
- **Ficha de un terreno**: calle, zona, lo que hay, m², fachada, extras del sitio, alquiler; y un
  botón grande: COMPRAR $X / CONSTRUIR CASAS $X · 20 s / HASTA TORRES $X · 57 min / EN OBRAS
  3:20 / AL MÁXIMO, o la razón en gris (te faltan $X, fuera de tu radio, grúas ocupadas).
- **Banco** y **Gerente**: pantallas completas con el botón de volver y su título, como todas.
- Todo lo que se pulsa mide al menos 44 px (usable con la ventana a 200 px).

## 10. Lo que dice la simulación (Valencia, Jesús-María; 130 terrenos)

`godot --headless --path . --script res://tools/econ_sim.gd -- --file=<oficina.json>`

| Hito | Ideal (siempre mirando) | Widget (un vistazo por hora, 4 clics) | Perezoso (3 veces al día, 6 clics) |
|---|---|---|---|
| Primera compra | 0 s | 0 s | 0 s |
| Primera obra acabada | 21 s | 21 s | 21 s |
| Primera Urbanización | 6 min | 6 min | 6 min |
| Oficina Nv 2 | 14 min | 1 h 10 min | 5 h |
| Primer gerente | 50 min | 5 h | 1 d |
| Oficina Nv 3 | 1 h 22 min | 6 h | 1 d 5 h |
| Primeras Torres | 3 h | 13 h | 2 d 12 h |
| Primer Rascacielos | 1 d | 1 d 6 h | 6 d |
| Oficina Nv 4 | 16 h | 2 d | 3 d 5 h |
| Oficina Nv 5 | 8 d 15 h | 9 d 4 h | 13 d 12 h |
| Todo el radio de 500 m tuyo | 9 d | 10 d | 17 d 12 h |
| Todo al máximo | 13 d | 13 d | 20 d |

(Los dos que juegan poco juegan los 10 primeros minutos como el ideal.) Con préstamos usados con
cabeza (rápido/normal para comprar ya lo que se paga en menos de 2 h, pago automático 25 %): Nv 2
en 4 min, Nv 3 en 56 min. Un jugador que pide lo máximo el día 2 sin pagar, pierde el gerente y se
va una semana: sigue ganando ($51,7B esa semana), su interés nunca pasa del 4,8 % de su alquiler,
paga al banco $6,2B y al volver con pago automático la deuda baja.

## 11. Más adelante (no está hecho)

- **Salir a bolsa** (prestigio): vender todo por acciones que dan +% permanente.
- **Recalificar** un terreno para pasar su límite (industrial → residencial).
- **Eventos de un clic**, discretos: un cliente con un bocadillo sobre un tejado (cobra 2 min de
  alquiler), una inspección, una oferta de compra. Solo si no molestan.
- **Día y noche** con ventanas encendidas.
