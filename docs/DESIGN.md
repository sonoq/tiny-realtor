# Tiny Realtor: diseño

*Nombre provisional. Juego idle de inmobiliaria sobre mapas reales, en una ventanita de 600x600 sin bordes y siempre encima, como Tiny Battlegrounds.*

Esto es lo decidido hasta ahora. Si algo choca con `FEASIBILITY.md` (el estudio anterior), manda este documento. Cómo se juega (dinero, compras, obras, banco, gerentes) está en `GAMEPLAY.md`.

## 1. La idea en una frase

Abres oficinas inmobiliarias en barrios reales del mundo, compras terrenos grandes en las calles de alrededor, construyes en ellos, cobras alquileres (también con el juego cerrado) y vas subiendo de nivel hasta tener rascacielos.

**Construyes tú; no se compran los edificios reales.** Del mapa real solo se usan las calles (con sus nombres), las zonas (residencial, comercial, industrial), los parques, el agua y las vías del tren. Las manzanas y los terrenos salen de las calles; los edificios los pone el juego.

## 2. Pantallas

### Mapa del mundo (hecho: es la primera pantalla)
- Un mapamundi en pixel art con los colores nocturnos del mapa de la ciudad, sacado de las costas, lagos y fronteras de **Natural Earth** (dominio público, `docs/NATURAL_EARTH.md`). Viene dentro del juego como cuatro imágenes (una por nivel de zoom, unos 265 KB); no se descarga nada.
- Se arrastra para moverlo y se acerca con la rueda o con + y − en saltos enteros: x1 (el mundo entero), x2, x4, x8 (Europa) y x16 (España, con Barcelona y Valencia ya separadas).
- Cada ciudad del juego es un puntito; al pasar el ratón se ve su nombre. Las ciudades donde tienes oficinas llevan la chincheta dorada (la misma que en la vista de la oficina) con el número de oficinas.
- Las ciudades que quedan demasiado juntas para pulsarlas se agrupan en un círculo con un número: si son pocas, al pulsarlo sale una lista pequeña; si son muchas, el mapa se acerca solo hasta separarlas.
- Pulsar una ciudad abre su mapa. Una ciudad con oficinas (o un grupo) abre la lista, donde cada oficina tiene su fila: pulsarla abre la oficina directamente.
- Arriba a la derecha, tu dinero y lo que ganas por minuto; un botón de lista abre la lista de ciudades de siempre.
- Volver: desde la oficina se va al mapa de su ciudad y de ahí al mapamundi (centrado en esa ciudad). Esc en el mapamundi cierra el juego. Al abrir el juego se sigue entrando directamente en la última oficina.

### Elegir ciudad
- Una lista de ciudades que viene **dentro del juego** (de **GeoNames**, por ejemplo las 500 más grandes, unos 30 KB). Hoy son 31 ciudades; la lista se abre desde el botón del mapamundi.
- No hay buscador en vivo: las normas del buscador público de OpenStreetMap (Nominatim) prohíben el autocompletado.

### Mapa de la ciudad
- Al entrar en una ciudad, el juego descarga solo los **nombres de los barrios y las avenidas principales** (unos pocos KB) y dibuja un plano sencillo en pixel art.
- Haces clic donde quieras poner una **oficina inmobiliaria**.

### Vista de la oficina (la vista principal)
- La zona alrededor de la oficina en isométrico pixel art: calles, edificios, parques.
- Aquí se compra, se construye y se mejora.

### Estilo visual (decidido: A, "hermano de Tiny Battlegrounds")
- El de la maqueta `docs/style_mockups/a_battlegrounds/`: fondo de pizarra oscura, paneles con remaches, letra pixel gruesa con borde oscuro, acentos cian, oro y menta, como Tiny Battlegrounds.
- El barrio es una maqueta flotante: dentro del radio de la oficina todo va a todo color; fuera, la ciudad es gris lila, como miniaturas sin pintar que vas conquistando, con un anillo dorado discontinuo en el borde.
- Lo tuyo lleva tejado turquesa y bandera cian; los solares en venta, cartel rojo con "$" y etiqueta de precio; el rascacielos, corona dorada; tu oficina no es un edificio: una chincheta dorada en la acera marca dónde la pusiste, y la oficina vive en su propia pestaña.
- Todo es pixel art de verdad: una sola paleta, sin mezclas de color, cada píxel del dibujo se ve como un bloque de 2x2.

## 3. Cómo se consiguen los mapas

- Fuente: **OpenStreetMap**, pedido directamente a la **API pública de Overpass**. Sin servidor propio: **0 € al mes**.
- Al poner una oficina se descarga **una sola vez** lo que hay en su radio **máximo** (500 m): **calles con sus nombres, vías de tren, zonas (usos del suelo), parques y agua. Nada de edificios** (la descarga es mucho más pequeña y rápida, y las calles son lo mejor mapeado del mundo).
- Con eso el juego calcula las **manzanas** (los huecos que dejan las calles) y las parte en **terrenos** grandes: una manzana pequeña es un solo terreno; una grande se corta en 2-4 trozos con cortes rectos, de unos 2.500-8.000 m², y **cada terreno da a una calle**. Cada terreno sabe **en qué calles está** (su dirección, por ejemplo "Carrer de Mallorca"), si es esquina, cuántos metros de fachada tiene y su zona. Los trocitos demasiado pequeños o estrechos se quedan como jardincillos.
- Así hay **pocas propiedades y grandes**: unas 100-150 en una oficina de 500 m (antes eran más de 2.000 parcelas pequeñas) y unas 10-15 dentro del radio de 150 m del nivel 1. Se pueden señalar y pulsar sin que nada estorbe.
- **Al construir en un terreno sale una pequeña urbanización entera, no un edificio**: casas = una fila de casas con jardín; urbanización = casas más grandes con piscina; bloque de pisos = varios bloques alrededor de un patio con árboles; torres = de una a tres torres en una plaza; rascacielos = un rascacielos sobre un zócalo en una plaza; en zona industrial, naves. El solar vacío es un terreno vallado con hierbajos y el cartel rojo de "se vende".
- Al empezar, una parte de los terrenos ya viene construida (más en zonas comerciales y en las calles grandes) con edificios del juego, para que el barrio no parezca un desierto; el resto son **solares vacíos**.
- Todo se **guarda para siempre** en el ordenador del jugador (unos 100-300 KB por oficina).
- Las oficinas guardadas con parcelas pequeñas (formato antiguo) se vuelven a partir en terrenos solas al abrirlas.
- **Nunca se actualiza.** Si alguien cambia el mapa real después, tu partida no se rompe.
- Para portarse bien con el servidor público: el juego se identifica con un nombre propio (User-Agent), reintenta si falla, prueba con un servidor espejo y, si todo está ocupado, dice "El servidor está ocupado, inténtalo en un rato".
- Google Maps está descartado: sus condiciones prohíben guardar sus datos.

## 4. Oficinas

- Cada oficina tiene un **nivel**. Su **radio activo** (la zona donde puedes comprar) crece con el nivel, por ejemplo **150 m en el nivel 1**, hasta el radio máximo ya descargado. Subir de nivel **nunca necesita internet**.
- Las oficinas tienen que estar **lejos unas de otras**: como mínimo el doble del radio máximo más un margen (por ejemplo **1,5 km**). Así sus zonas nunca se tocan y cada oficina es una isla independiente; nunca hay que pegar mapas descargados en fechas distintas.
- Puedes tener **varias oficinas en una ciudad** y en **muchas ciudades**.

## 5. Dentro del radio de una oficina

- **Comprar** terrenos (vacíos o ya construidos) y **construir** en ellos.
- **Señalar un terreno** lo marca con un borde cian (gris si está fuera de tu radio); **pulsarlo** lo marca en dorado y abre una ficha con la calle, la zona, lo que hay construido, los m², los metros de fachada, si es esquina y el precio (de momento inventado: m² x 300 $). Esc o la X cierran la ficha.
- **Alquiler por minuto**, también con el juego cerrado (con un tope).
- **Mejoras**, por este orden: **Solar → Casas → Urbanización → Bloque de pisos → Torres → Rascacielos** (cada nivel llena el terreno entero).
- El **tamaño del terreno** (sale de la manzana real) y la **zona** limitan lo que puedes construir. Pasar de ese límite exige una **recalificación**, que es un objetivo caro.
- **El valor sale de los datos reales:** parques, metro, colegios y tiendas cerca suben el alquiler. Las **esquinas** pagan más, y tener la **manzana entera** da un extra.
- **Eventos pequeños de un clic** (inquilino moroso, inspección, oferta de compra...).
- **Prestigio:** "salir a bolsa" para empezar de nuevo con ventajas permanentes.
- **Día y noche**, con ventanas que se encienden.

## 6. Licencia de los mapas

- Los datos de OpenStreetMap son **ODbL**: hay que mostrar **"© OpenStreetMap contributors"** de forma visible en el juego (y en créditos y la tienda).
- Lo que se guarda en el ordenador de cada jugador es su caché privada, no una distribución pública de los datos.

## 7. Tamaños (medidos en noviembre de 2026)

- El juego pesará unos **105 MB**, casi todo el motor Godot.
- **Mapa de una ciudad** (caja de 8 x 8 km: avenidas principales, mar, ríos, parques grandes y nombres de barrios): **2,8-3,6 MB** de descarga una sola vez, se guarda en **160-250 KB**.
- **Zona de una oficina** (500 m, solo calles, zonas, parques, agua y vías; sin edificios):

| Sitio | Descarga | Terrenos (antes parcelas) | En el radio de 150 m | Cálculo | Guardado |
|---|---|---|---|---|---|
| Valencia, Jesús-María (el Botànic) | 319 KB | 130 (antes 2.177) | 13 (antes 218) | 0,15 s | 137 KB |
| Barcelona, Eixample | 318 KB | 114-117 (antes 1.851) | 12 (antes 156) | 0,15 s | 115 KB |
| Tokio, Shibuya | 461 KB | 140 (antes 2.167) | 13 (antes 191) | 0,25 s | 151 KB |
| Varsovia, Centrum | 962 KB | 130-137 (antes 2.498) | 11 (antes 170) | 0,2 s | 285 KB |
| Helsinki, Kluuvi | 1,2 MB | 96 (antes 1.378) | 10 (antes 118) | 0,3 s | 211 KB |

- Cuánto tarda la descarga depende de cómo estén los servidores públicos: desde la nube de pruebas, entre **1,5 y 6 minutos** (uno de los tres servidores no contestaba nunca y otro a ratos); a veces los tres estaban ocupados y el juego enseñó el aviso de "inténtalo dentro de un rato". En un PC normal debería ser bastante menos.
- El radio máximo se queda en **500 m**: sin edificios la descarga es pequeña incluso en el centro de Tokio.

## 8. Qué hay hecho

- **El prototipo del mapa, con datos reales**: lista de 31 ciudades, mapa de la ciudad (se mueve arrastrando, 3 niveles de zoom, nombres de barrios), cursor con el círculo de la oficina (rojo si está a menos de 1,5 km de otra), confirmar, pantalla de descarga (con reintentos y servidores de reserva), y la vista de la oficina en isométrico: calles reales con sus nombres, manzanas y terrenos calculados, solares vacíos con cartel de "se vende", urbanizaciones del juego en los terrenos construidos, terrenos que se señalan y se pulsan con su ficha, parques, agua, vías del tren y el radio activo iluminado.
- **El primer bucle de juego** (todo el detalle en `GAMEPLAY.md`): dinero y alquiler por minuto (también con el juego cerrado, con tope), comprar terrenos dentro del radio, construir (uno o varios niveles de golpe; la obra se ve con andamios y grúa), subir la oficina de nivel (el radio crece), el banco (tres préstamos que nunca te ahogan, pago automático) y un gerente por oficina (retrato pixel art, rareza, bonus). La oficina no ocupa terreno: es una pestaña (nivel, obras solas, gerente, y sitio para lo que vendrá) con una chincheta en el mapa; el terreno donde la pones es tuyo, gratis, como solar para construir.
- **La partida se guarda** (`save.json`) y al abrir el juego vuelve a la última oficina, con el resumen de "Mientras no estabas".
- Las oficinas y los mapas se guardan y siguen ahí al volver a abrir el juego.
- Modo de prueba sin internet (`-- --fixture`): datos inventados, marcados en pantalla como DATOS DE PRUEBA, con su propia partida aparte.
- El prototipo en Python del estudio está en `docs/prototype/`.
