class_name Overpass
extends Node

# Downloads one Overpass API query, politely: a named User-Agent, one request at a time, retries
# with growing waits, and a different public mirror on each try. Emits the raw response bytes;
# the caller parses and bakes them off the main thread.
#
# Networking notes: on a normal PC Godot's defaults just work. In the cloud dev container all
# HTTPS goes through a proxy (env HTTPS_PROXY) that re-signs TLS with its own CA, which Godot
# does not pick up by itself, so the proxy and the CA bundle are set by hand only when present.
#
# Debug: `-- --fixture` (or env TINY_REALTOR_FIXTURE=1) never touches the network and answers with
# made-up test data from Fixture; the game then shows a DATOS DE PRUEBA tag on every map screen.
# `-- --raw-cache=DIR` (dev only) keeps each raw response in DIR keyed by the query, so a bake can
# be re-run without downloading again.

signal status(text: String)
signal progress(bytes: int)
signal finished(body: PackedByteArray, info: Dictionary)
signal failed(reason: String)

const MIRRORS: Array[String] = [
	"https://overpass-api.de/api/interpreter",
	"https://overpass.kumi.systems/api/interpreter",
	"https://overpass.private.coffee/api/interpreter",
]
const USER_AGENT := "TinyRealtor/0.1"
# seconds to wait before try 2, 3, ...; the public servers ask clients to back off when busy
const WAITS: Array[float] = [2.0, 5.0, 10.0, 20.0, 30.0]
const TIMEOUT_S := 150.0
const BODY_LIMIT := 64 * 1024 * 1024
const CLOUD_CA := "/root/.ccr/ca-bundle.crt"
const BUSY := "El servidor de mapas está ocupado. Inténtalo dentro de un rato."

static var fixture_mode := false
static var raw_cache := ""

var _http: HTTPRequest
var _query := ""
var _fake: Callable
var _try := 0
var _started := 0
var _wait := 0.0
var _busy := false


# reads the debug switches once; main.gd calls this at start
static func read_flags() -> void:
	fixture_mode = OS.get_environment("TINY_REALTOR_FIXTURE") == "1"
	for arg in OS.get_cmdline_user_args():
		if arg == "--fixture":
			fixture_mode = true
		elif arg.begins_with("--raw-cache="):
			raw_cache = arg.substr(12)


func busy() -> bool:
	return _busy


# `fake` builds the test response used in fixture mode
func fetch(query: String, fake: Callable) -> void:
	cancel()
	_query = query
	_fake = fake
	_try = 0
	_busy = true
	_started = Time.get_ticks_msec()
	var cached := _cache_file()
	if fixture_mode:
		status.emit("Generando datos de prueba (sin conexión)…")
		_wait = 0.6
		return
	if cached != "" and FileAccess.file_exists(cached):
		_finish(FileAccess.get_file_as_bytes(cached), {"cached": true, "mirror": "raw-cache"})
		return
	_attempt()


func cancel() -> void:
	if _http != null:
		_http.cancel_request()
		_http.queue_free()
		_http = null
	_busy = false
	_wait = 0.0


func _process(delta: float) -> void:
	if not _busy:
		return
	if _wait > 0.0:
		_wait -= delta
		if _wait <= 0.0:
			if fixture_mode:
				var body := JSON.stringify(_fake.call()).to_utf8_buffer()
				_finish(body, {"fixture": true, "mirror": "fixture"})
			else:
				_attempt()
	elif _http != null:
		progress.emit(_http.get_downloaded_bytes())


func _attempt() -> void:
	var url := MIRRORS[_try % MIRRORS.size()]
	_http = HTTPRequest.new()
	_http.timeout = TIMEOUT_S
	_http.body_size_limit = BODY_LIMIT
	_http.accept_gzip = true
	_http.use_threads = true
	add_child(_http)
	_configure_network(_http)
	_http.request_completed.connect(_on_done)
	var headers := PackedStringArray(["User-Agent: " + USER_AGENT,
		"Content-Type: application/x-www-form-urlencoded"])
	var err := _http.request(url, headers, HTTPClient.METHOD_POST, "data=" + _query.uri_encode())
	if err != OK:
		_retry("no se pudo conectar (%d)" % err)
		return
	status.emit("Descargando de %s…" % url.get_slice("/", 2))


# proxy and CA only when the machine has them (the cloud container); a plain PC uses defaults
static func _configure_network(http: HTTPRequest) -> void:
	var proxy := OS.get_environment("HTTPS_PROXY")
	if proxy == "":
		proxy = OS.get_environment("https_proxy")
	if proxy != "":
		var hostport := proxy.trim_prefix("http://").trim_prefix("https://").trim_suffix("/")
		hostport = hostport.get_slice("@", hostport.get_slice_count("@") - 1)
		var host := hostport.get_slice(":", 0)
		var port := int(hostport.get_slice(":", 1)) if hostport.contains(":") else 80
		http.set_https_proxy(host, port)
	var ca := OS.get_environment("SSL_CERT_FILE")
	if ca == "" or not FileAccess.file_exists(ca):
		ca = CLOUD_CA
	if FileAccess.file_exists(ca):
		var cert := X509Certificate.new()
		if cert.load(ca) == OK:
			http.set_tls_options(TLSOptions.client(cert))


func _on_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _http != null:
		_http.queue_free()
		_http = null
	if not _busy:
		return
	var mirror := MIRRORS[_try % MIRRORS.size()].get_slice("/", 2)
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		# Overpass answers 200 with a "remark" when a query ran out of time or memory
		var tail := body.slice(maxi(0, body.size() - 600)).get_string_from_utf8()
		if tail.contains("runtime error") or tail.contains("runtime remark"):
			_retry("el servidor no terminó la consulta")
			return
		var info := {"mirror": mirror, "tries": _try + 1}
		var cached := _cache_file()
		if cached != "":
			DirAccess.make_dir_recursive_absolute(cached.get_base_dir())
			var f := FileAccess.open(cached, FileAccess.WRITE)
			if f != null:
				f.store_buffer(body)
		_finish(body, info)
	elif result == HTTPRequest.RESULT_SUCCESS and code == 400:
		_busy = false
		failed.emit("El servidor no entendió la petición (error 400).")
	elif result == HTTPRequest.RESULT_SUCCESS:
		_retry("%s respondió %d" % [mirror, code])
	else:
		_retry("%s no responde (%s)" % [mirror, _result_name(result)])


func _retry(why: String) -> void:
	print("Overpass: try %d failed: %s" % [_try + 1, why])
	if _try >= WAITS.size():
		_busy = false
		failed.emit(BUSY)
		return
	_wait = WAITS[_try]
	_try += 1
	status.emit("Servidor ocupado, reintentando en %d s (intento %d de %d)…" % [
		ceili(_wait), _try + 1, WAITS.size() + 1])


func _finish(body: PackedByteArray, info: Dictionary) -> void:
	_busy = false
	info["bytes"] = body.size()
	info["ms"] = Time.get_ticks_msec() - _started
	finished.emit(body, info)


func _cache_file() -> String:
	if raw_cache == "" or fixture_mode:
		return ""
	return raw_cache.path_join(_query.md5_text() + ".json")


static func _result_name(result: int) -> String:
	match result:
		HTTPRequest.RESULT_CANT_CONNECT:
			return "sin conexión"
		HTTPRequest.RESULT_CANT_RESOLVE:
			return "no encuentra el servidor"
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "conexión cortada"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "fallo TLS"
		HTTPRequest.RESULT_TIMEOUT:
			return "tiempo agotado"
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
			return "respuesta demasiado grande"
	return "error %d" % result
