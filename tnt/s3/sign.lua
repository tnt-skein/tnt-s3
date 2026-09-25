--- Подпись запросов S3 по AWS Signature Version 4.
---
--- Подпись — это HMAC-SHA256 над каноническим видом запроса: метод, путь,
--- строка параметров, подписанные заголовки и свёртка тела. Сервер собирает
--- тот же вид из того, что получил, и сверяет. Поэтому главное правило
--- модуля — **подписывается ровно то, что уходит**: строку параметров
--- и путь отсюда же кладут в адрес, и второго кодировщика, который однажды
--- закодирует иначе, нет. Кодирует `tnt.http.url` — тот же, что у клиента
--- HTTP: только буквы латиницы, цифры и `-._~` остаются как есть, прочее —
--- `%XX` прописными (так требует SigV4).
---
--- Ключ подписи выводится из секрета цепочкой HMAC — дата, область, служба —
--- и считается на каждый запрос заново: четыре HMAC стоят микросекунды,
--- а кэш ключа по дате пришлось бы сторожить на смене суток.
---
--- Модуль чистый: ни сети, ни часов. Миг подписи (`stamp`) приходит
--- аргументом — иначе его не проверить на примерах AWS, где миг назван.

local hash = require('tnt.hash')
local url = require('tnt.http.url')

local Module = {}

--- Алгоритм подписи: имя из заголовка `Authorization`.
Module.ALGORITHM = 'AWS4-HMAC-SHA256'

--- Служба, для которой выводится ключ.
Module.SERVICE = 's3'

--- Свёртка тела у ссылки с подписью: тела у неё ещё нет.
Module.UNSIGNED = 'UNSIGNED-PAYLOAD'

--- Последнее звено области подписи.
local TERMINATOR = 'aws4_request'

--- Дата мига подписи: первые восемь цифр `20130524T000000Z`.
---
--- Восемь цифр названы поштучно, а не повтором: у `%d+` мутант `%d*`
--- берёт те же восемь и неотличим.
local DATE = '^(%d%d%d%d%d%d%d%d)'

---@class TntS3Credentials Кто подписывает и где
---@field access_key string Опознаватель ключа
---@field secret_key string Секрет ключа
---@field session_token string|nil Временный токен STS
---@field region string Область

---@class TntS3Unsigned Запрос до подписи
---@field method string Метод прописными
---@field path string Путь, уже закодированный: `path`
---@field query string Строка параметров в каноническом виде: `query`
---@field headers table<string, string> Заголовки, имена строчными; host обязателен
---@field payload string Свёртка тела sha256 в hex

--- Путь в каноническом виде: каждый отрезок кодируется, косые черты — нет.
---
--- S3 кодирует путь один раз, а не дважды, как прочие службы AWS, и точек
--- не сворачивает: ключ `a/./b` — это ключ, а не путь. Сворачивает их
--- libcurl, поэтому такие ключи отсекает фасад, а не этот модуль.
---@param path string Путь как есть, с ведущей косой чертой
---@return string
function Module.path(path)
    local segments = path:split('/')

    for index, segment in ipairs(segments) do
        segments[index] = url.encode(segment)
    end

    return table.concat(segments, '/')
end

--- Строка параметров в каноническом виде: имена и значения закодированы,
--- порядок — по закодированному имени.
---
--- Имён-повторов у S3 не бывает, поэтому параметры — словарь: значение
--- пустой строкой даёт `имя=`, так пишутся и подресурсы вроде `uploads`;
--- незаданное (`nil`) в строку не попадает.
---@param params table<string, string|nil>
---@return string
function Module.query(params)
    local names = {}
    local encoded = {}

    for name, value in pairs(params) do
        local key = url.encode(name)

        table.insert(names, key)
        encoded[key] = url.encode(value)
    end

    -- Порядок — по именам, а не по строкам `имя=значение` целиком: знаки
    -- `-`, `.`, `%` и цифры меньше `=`, и `a-b=1` встало бы раньше `a=2`,
    -- хотя SigV4 требует `a` раньше `a-b`.
    table.sort(names)

    local parts = {}

    for index, key in ipairs(names) do
        parts[index] = key .. '=' .. encoded[key]
    end

    return table.concat(parts, '&')
end

--- Миг подписи: `20130524T000000Z`, время UTC.
---@param seconds number Секунды от начала эпохи
---@return string
function Module.stamp(seconds)
    return os.date('!%Y%m%dT%H%M%SZ', math.floor(seconds)) --[[@as string]]
end

--- Значение заголовка в каноническом виде: без пробелов по краям,
--- пробелы подряд — одним.
---@param value string
---@return string
local function trimmed(value)
    return (value:strip():gsub(' +', ' '))
end

--- Подписанные заголовки: блок строк `имя:значение` и список имён.
---@param headers table<string, string>
---@return string block
---@return string signed
local function canonical_headers(headers)
    local names = {}

    for name in pairs(headers) do
        table.insert(names, name)
    end

    table.sort(names)

    local lines = {}

    for index, name in ipairs(names) do
        lines[index] = ('%s:%s\n'):format(name, trimmed(headers[name]))
    end

    return table.concat(lines), table.concat(names, ';')
end

--- Область подписи: дата, область, служба.
---@param credentials TntS3Credentials
---@param stamp string
---@return string
local function scope_of(credentials, stamp)
    return ('%s/%s/%s/%s'):format(stamp:match(DATE), credentials.region, Module.SERVICE, TERMINATOR)
end

--- Ключ подписи: секрет, пропущенный через дату, область и службу.
---@param credentials TntS3Credentials
---@param stamp string
---@return string
local function signing_key(credentials, stamp)
    local date = stamp:match(DATE) --[[@as string]]
    local key = hash.hmac('sha256', 'AWS4' .. credentials.secret_key, date, 'raw')

    key = hash.hmac('sha256', key, credentials.region, 'raw')
    key = hash.hmac('sha256', key, Module.SERVICE, 'raw')

    return hash.hmac('sha256', key, TERMINATOR, 'raw')
end

--- Подпись канонического запроса.
---@param credentials TntS3Credentials
---@param stamp string
---@param canonical string
---@return string signature
---@return string scope
local function signature_of(credentials, stamp, canonical)
    local scope = scope_of(credentials, stamp)
    local text = table.concat({ Module.ALGORITHM, stamp, scope, hash.digest('sha256', canonical) }, '\n')

    return hash.hmac('sha256', signing_key(credentials, stamp), text), scope
end

--- Подписывает запрос: заголовки для отправки вместе с `authorization`.
---
--- Кроме заданных, подписываются `x-amz-date`, `x-amz-content-sha256`
--- и токен сессии: их модуль ставит сам, и отправить их неподписанными
--- нельзя — S3 требует подписи всякого `x-amz-*`. Прочее, что добавят
--- libcurl и клиент HTTP после подписи (`content-length`, `accept`,
--- `x-request-id`), не подписывается и серверу не мешает.
---@param credentials TntS3Credentials
---@param request TntS3Unsigned
---@param stamp string Миг подписи из `stamp`
---@return table<string, string> headers Новая таблица: заданные и подписи
function Module.headers(credentials, request, stamp)
    ---@type table<string, string>
    local headers = {}

    for name, value in pairs(request.headers) do
        headers[name] = value
    end

    headers['x-amz-date'] = stamp
    headers['x-amz-content-sha256'] = request.payload
    headers['x-amz-security-token'] = credentials.session_token

    local block, signed = canonical_headers(headers)
    local canonical = table.concat({
        request.method,
        request.path,
        request.query,
        block,
        signed,
        request.payload,
    }, '\n')
    local signature, scope = signature_of(credentials, stamp, canonical)

    headers.authorization = ('%s Credential=%s/%s, SignedHeaders=%s, Signature=%s'):format(
        Module.ALGORITHM,
        credentials.access_key,
        scope,
        signed,
        signature
    )

    return headers
end

--- Строка параметров ссылки с подписью: всё, что нужно серверу, едет в ней.
---
--- Подписан только заголовок `host`, тело — нет (`UNSIGNED-PAYLOAD`):
--- ссылку отдают браузеру или чужой программе, и какие заголовки поставят
--- они, заранее не знает никто.
---@param credentials TntS3Credentials
---@param request { method: string, path: string, host: string, params: table<string, string>|nil }
---@param stamp string Миг подписи из `stamp`
---@param expires integer Сколько секунд ссылка годна
---@return string query Строка параметров без ведущего знака вопроса
function Module.presign(credentials, request, stamp, expires)
    ---@type table<string, string>
    local params = {}

    for name, value in pairs(request.params or {}) do
        params[name] = value
    end

    params['X-Amz-Algorithm'] = Module.ALGORITHM
    params['X-Amz-Credential'] = ('%s/%s'):format(credentials.access_key, scope_of(credentials, stamp))
    params['X-Amz-Date'] = stamp
    params['X-Amz-Expires'] = tostring(expires)
    params['X-Amz-SignedHeaders'] = 'host'
    params['X-Amz-Security-Token'] = credentials.session_token

    local query = Module.query(params)
    local canonical = table.concat({
        request.method,
        request.path,
        query,
        ('host:%s\n'):format(request.host),
        'host',
        Module.UNSIGNED,
    }, '\n')

    return ('%s&X-Amz-Signature=%s'):format(query, (signature_of(credentials, stamp, canonical)))
end

return Module
