# Tiny Realtor: diseño

*Nombre provisional. Juego idle de inmobiliaria sobre mapas reales, en una ventanita de 600x600 sin bordes y siempre encima, como Tiny Battlegrounds.*

Esto es lo decidido hasta ahora. Si algo choca con `FEASIBILITY.md` (el estudio anterior), manda este documento.

## 1. La idea en una frase

Abres oficinas inmobiliarias en barrios reales del mundo, compras solares en las calles de alrededor, construyes en ellos, cobras alquileres (también con el juego cerrado) y vas subiendo de nivel hasta tener rascacielos.

**Construyes tú; no se compran los edificios reales.** Del mapa real solo se usan las calles (con sus nombres), las zonas (residencial, comercial, industrial), los parques, el agua y las vías del tren. Las manzanas y las parcelas salen de las calles; los edificios los pone el juego.

## 2. Pantallas

### Mapa del mundo
- Un mapa del mundo en pixel art, dibujado con matemáticas a partir de las costas de **Natural Earth** (dominio público). Se hará más adelante.
- En él se ven tus oficinas repartidas por las ciudades.

### Elegir ciudad
- Una lista de ciudades que viene **dentro del juego** (de **GeoNames**, por ejemplo las 500 más grandes, unos 30 KB).
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
- Lo tuyo lleva tejado turquesa y bandera cian; los solares en venta, cartel rojo con "$" y etiqueta de precio; el rascacielos, corona dorada; tu oficina, el cartel REALTOR.
- Todo es pixel art de verdad: una sola paleta, sin mezclas de color, cada píxel del dibujo se ve como un bloque de 2x2.

## 3. Cómo se consiguen los mapas

- Fuente: **OpenStreetMap**, pedido directamente a la **API pública de Overpass**. Sin servidor propio: **0 € al mes**.
- Al poner una oficina se descarga **una sola vez** lo que hay en su radio **máximo** (500 m): **calles con sus nombres, vías de tren, zonas (usos del suelo), parques y agua. Nada de edificios** (la descarga es mucho más pequeña y rápida, y las calles son lo mejor mapeado del mundo).
- Con eso el juego calcula las **manzanas** (los huecos que dejan las calles) y las parte en **parcelas** a lo largo de la fachada, como en la realidad: una franja de parcelas alrededor de cada manzana, las de esquina dan a dos calles y el centro queda como patio de manzana. Cada parcela sabe **en qué calle está** (su dirección, por ejemplo "Carrer de Mallorca") y su zona.
- Al empezar, la mayoría de parcelas son **solares vacíos**; una parte ya viene construida (más en zonas comerciales y en las calles grandes) con edificios del juego, para que el barrio no parezca un desierto.
- Todo se **guarda para siempre** en el ordenador del jugador (unos 500-800 KB por oficina).
- **Nunca se actualiza.** Si alguien cambia el mapa real después, tu partida no se rompe.
- Para portarse bien con el servidor público: el juego se identifica con un nombre propio (User-Agent), reintenta si falla, prueba con un servidor espejo y, si todo está ocupado, dice "El servidor está ocupado, inténtalo en un rato".
- Google Maps está descartado: sus condiciones prohíben guardar sus datos.

## 4. Oficinas

- Cada oficina tiene un **nivel**. Su **radio activo** (la zona donde puedes comprar) crece con el nivel, por ejemplo **150 m en el nivel 1**, hasta el radio máximo ya descargado. Subir de nivel **nunca necesita internet**.
- Las oficinas tienen que estar **lejos unas de otras**: como mínimo el doble del radio máximo más un margen (por ejemplo **1,5 km**). Así sus zonas nunca se tocan y cada oficina es una isla independiente; nunca hay que pegar mapas descargados en fechas distintas.
- Puedes tener **varias oficinas en una ciudad** y en **muchas ciudades**.

## 5. Dentro del radio de una oficina

- **Comprar** solares (y las parcelas que ya traen edificio) y **construir** en ellos.
- **Alquiler por minuto**, también con el juego cerrado (con un tope).
- **Mejoras**, por este orden: **Solar → Casa → Urbanización** (une 2-4 parcelas vecinas) **→ Bloque de pisos → Torre → Rascacielos**.
- El **tamaño de la parcela** (sale de la manzana real) y la **zona** limitan lo que puedes construir. Pasar de ese límite exige una **recalificación**, que es un objetivo caro.
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

| Sitio | Descarga | Parcelas | Cálculo | Guardado |
|---|---|---|---|---|
| Barcelona, Eixample | 318 KB | 1.851 (924 ya construidas) | 0,16 s | 525 KB |
| Tokio, Shibuya | 461 KB | 2.167 (1.064 ya construidas) | 0,31 s | 620 KB |
| Varsovia, Centrum | 962 KB | 2.498 (1.223 ya construidas) | 0,30 s | 788 KB |
| Helsinki, Kluuvi | 1,2 MB | 1.429 | 0,3 s | 527 KB |

- Cuánto tarda la descarga depende de cómo estén los servidores públicos: desde la nube de pruebas, entre **1,5 y 6 minutos** (uno de los tres servidores no contestaba nunca y otro a ratos); a veces los tres estaban ocupados y el juego enseñó el aviso de "inténtalo dentro de un rato". En un PC normal debería ser bastante menos.
- El radio máximo se queda en **500 m**: sin edificios la descarga es pequeña incluso en el centro de Tokio.

## 8. Qué hay hecho

- **El prototipo del mapa, con datos reales**: lista de 31 ciudades, mapa de la ciudad (se mueve arrastrando, 3 niveles de zoom, nombres de barrios), cursor con el círculo de la oficina (rojo si está a menos de 1,5 km de otra), confirmar, pantalla de descarga (con reintentos y servidores de reserva), y la vista de la oficina en isométrico: calles reales con sus nombres, manzanas y parcelas calculadas, solares vacíos con cartel de "se vende", edificios del juego, parques, agua, vías del tren, tu oficina marcada y el radio activo (150 m) iluminado.
- Las oficinas y los mapas se guardan y siguen ahí al volver a abrir el juego.
- Modo de prueba sin internet (`-- --fixture`): datos inventados, marcados en pantalla como DATOS DE PRUEBA.
- Todavía no hay juego: ni dinero, ni compras, ni construir.
- El prototipo en Python del estudio está en `docs/prototype/`.
