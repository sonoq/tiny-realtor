# Tiny Realty: diseño

*Nombre provisional. Juego idle de inmobiliaria sobre mapas reales, en una ventanita de 600x600 sin bordes y siempre encima, como Tiny Battlegrounds.*

Esto es lo decidido hasta ahora. Si algo choca con `FEASIBILITY.md` (el estudio anterior), manda este documento.

## 1. La idea en una frase

Abres oficinas inmobiliarias en barrios reales del mundo, compras edificios y solares a su alrededor, cobras alquileres (también con el juego cerrado) y vas subiendo de nivel hasta tener rascacielos.

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

## 3. Cómo se consiguen los mapas

- Fuente: **OpenStreetMap**, pedido directamente a la **API pública de Overpass**. Sin servidor propio: **0 € al mes**.
- Al poner una oficina se descarga **una sola vez** todo lo que hay en su radio **máximo** (unos 500 m): edificios, calles, usos del suelo y parques.
- Eso se convierte en parcelas del juego y se **guarda para siempre** en el ordenador del jugador (unos 200-500 KB por oficina).
- **Nunca se actualiza.** Si alguien cambia el mapa real después, tu partida no se rompe.
- Para portarse bien con el servidor público: el juego se identifica con un nombre propio (User-Agent), reintenta si falla, prueba con un servidor espejo y, si todo está ocupado, dice "El servidor está ocupado, inténtalo en un rato".
- Google Maps está descartado: sus condiciones prohíben guardar sus datos.

## 4. Oficinas

- Cada oficina tiene un **nivel**. Su **radio activo** (la zona donde puedes comprar) crece con el nivel, por ejemplo **150 m en el nivel 1**, hasta el radio máximo ya descargado. Subir de nivel **nunca necesita internet**.
- Las oficinas tienen que estar **lejos unas de otras**: como mínimo el doble del radio máximo más un margen (por ejemplo **1,5 km**). Así sus zonas nunca se tocan y cada oficina es una isla independiente; nunca hay que pegar mapas descargados en fechas distintas.
- Puedes tener **varias oficinas en una ciudad** y en **muchas ciudades**.

## 5. Dentro del radio de una oficina

- **Comprar** edificios y solares.
- **Alquiler por minuto**, también con el juego cerrado (con un tope).
- **Mejoras**, por este orden: **Solar → Casa → Urbanización** (une 2-4 parcelas vecinas) **→ Bloque de pisos → Torre → Rascacielos**.
- El **tamaño real de la parcela** y la **altura habitual del barrio** limitan lo que puedes construir. Pasar de ese límite exige una **recalificación**, que es un objetivo caro.
- **El valor sale de los datos reales:** parques, metro, colegios y tiendas cerca suben el alquiler. Las **esquinas** pagan más, y tener la **manzana entera** da un extra.
- **Eventos pequeños de un clic** (inquilino moroso, inspección, oferta de compra...).
- **Prestigio:** "salir a bolsa" para empezar de nuevo con ventajas permanentes.
- **Día y noche**, con ventanas que se encienden.

## 6. Licencia de los mapas

- Los datos de OpenStreetMap son **ODbL**: hay que mostrar **"© OpenStreetMap contributors"** de forma visible en el juego (y en créditos y la tienda).
- Lo que se guarda en el ordenador de cada jugador es su caché privada, no una distribución pública de los datos.

## 7. Tamaños (estimados, todavía sin medir)

- El juego pesará unos **105 MB**, casi todo el motor Godot.
- Una zona de 500 m en el centro de una ciudad densa: **3.000-8.000 edificios**, **2-5 MB** de descarga en bruto, **5-20 segundos** de descarga.

## 8. Qué hay hecho

- Un proyecto de Godot 4.7.1 con la ventana de 600x600 y una vista que dibuja una zona de muestra (`data/sample_block.json`, un Eixample inventado a mano) en isométrico pixel art. Se puede arrastrar con el botón derecho.
- Todavía no hay juego: ni compras, ni dinero, ni descargas reales.
- El prototipo en Python del estudio está en `docs/prototype/`.
