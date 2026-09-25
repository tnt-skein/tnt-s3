--- S3 по договору драйвера хранилища: подпись SigV4 поверх `tnt-http`
--- и `tnt-hash`, срок, повторы и отказ парой.
---
---     local s3 = require('tnt.s3')
---
---     local bucket = s3.new({
---         endpoint = 'https://s3.eu-central-1.amazonaws.com',
---         region = 'eu-central-1',
---         bucket = 'backups',
---         access_key = key_id,
---         secret_key = secret,
---     })
---
---     local stored, err = bucket:put('reports/2026-09.csv', text, { content_type = 'text/csv' })
---     local body, info = bucket:get('reports/2026-09.csv')    -- нет объекта — nil без err
---     local page = bucket:list({ prefix = 'reports/', limit = 100 })
---     local link = bucket:presign('reports/2026-09.csv', { expires = 600 })
---     bucket:put_file('snapshots/00000042.snap', '/var/lib/tarantool/00000042.snap')  -- частями
---     local reader = bucket:reader('snapshots/00000042.snap')   -- кусками, по Range
---
--- Готового клиента S3 у Tarantool нет — ни в ядре, ни среди официальных
--- роков, — а чужие на luarocks.org ходят в сеть мимо файберов. Протокол
--- здесь свой только наполовину: HTTP — это `tnt-http` (libcurl со своим
--- кэшем соединений), подпись — `tnt-hash`, файлы — `tnt-fs`. Своё —
--- подпись SigV4 (`tnt.s3.sign`), чтение ответов (`tnt.s3.reply`),
--- обращение с попытками (`tnt.s3.call`), чтение кусками по диапазону
--- (`tnt.s3.download`) и загрузка частями (`tnt.s3.upload`).
--- Всё прочее — общее для драйверов хранилищ: отказ и срок из
--- `tnt-storage`, повторы из `tnt-retry`.
---
--- Решения, которые стоит знать заранее:
---
--- * **Отказ — пара `nil, err`**, где `err` — `TntStorageFailure`. Род —
---   по коду ответа (403 — `denied`, 503 `SlowDown` — `busy`, 500 —
---   `broken`) и по словам libcurl для сети; код S3 (`NoSuchBucket`) —
---   в `server_code` и в тексте. Исключение — только ошибка программиста:
---   негодный ключ, незнакомая настройка, значение, которого не передать.
--- * **Промах — `nil` без отказа**, как у `box.space:get`: `get` и `head`
---   объекта, которого нет. Нет ведра — отказ: это не промах, а настройка.
--- * **Срок один на вызов**, умолчание 5 с: попытки и паузы между ними —
---   остатки одного мига. Остаток уходит в `tnt-http` сроком обращения.
--- * **Повторы — драйвера, а не клиента HTTP.** У клиента их нет вовсе
---   (`attempts = 1`), драйвер повторяет по роду отказа. Все действия
---   S3 здесь идемпотентны по RFC 9110 — GET, HEAD, PUT, DELETE, — поэтому
---   обрыв и срок после отправки повторяются без просьбы; не согласный
---   на это ставит `idempotent = false`.
--- * **Транзакций нет** (`features.transaction = false`).
--- * **`put` и `get` — тело строкой целиком**, предел ответа — `max_bytes`,
---   16 МБ по умолчанию. Большое — кусками: `writer` копит часть
---   и отправляет её загрузкой частями, `reader` просит объект по куску
---   с `Range`, а `put_file` и `get_file` переливают файл через них.
---
--- Подробно — `docs/s3.md`.

local hash = require('tnt.hash')
local http = require('tnt.http')
local must = require('tnt.must')
local retry = require('tnt.retry')

local call = require('tnt.s3.call')
local download = require('tnt.s3.download')
local reply = require('tnt.s3.reply')
local settings_of = require('tnt.s3.settings')
local sign = require('tnt.s3.sign')
local transfer = require('tnt.s3.transfer')
local upload = require('tnt.s3.upload')

local Module = {}

--- Подменяет часы подписи. Только для проверок.
Module._set_source = call._set_source

--- Самый длинный ключ, который принимает S3: 1024 байта.
Module.MAX_KEY = call.MAX_KEY

--- Самый долгий срок ссылки с подписью: семь суток, дольше S3 не принимает.
Module.MAX_EXPIRES = 7 * 24 * 60 * 60

--- Срок ссылки по умолчанию: 15 минут.
---
--- Ссылка — тот же ключ доступа, только к одному объекту, и живёт она
--- столько, на сколько её выдали: отозвать её нельзя. Короткий срок —
--- умолчание, длинный просят явно.
Module.DEFAULT_EXPIRES = 15 * 60

--- Самая длинная страница списка: больше S3 не отдаёт.
Module.MAX_LIST = 1000

--- Вид содержимого, когда его не назвали.
Module.DEFAULT_TYPE = call.DEFAULT_TYPE

--- Часть загрузки по умолчанию: 8 МБ (`writer`, `put_file`).
Module.PART_SIZE = upload.PART_SIZE

--- Кусок чтения по умолчанию: 8 МБ (`reader`, `get_file`).
Module.PIECE = download.PIECE

--- Как драйвер представляется службе.
local USER_AGENT = 'tnt-s3'

--- Настройки записи.
local PUT = {
    timeout = '?number',
    idempotent = '?boolean',
    content_type = '?not_empty',
    metadata = '?table',
}

--- Настройки списка.
local LIST = {
    timeout = '?number',
    idempotent = '?boolean',
    prefix = '?string',
    delimiter = '?not_empty',
    after = '?not_empty',
    limit = '?integer',
}

--- Настройки ссылки с подписью.
local PRESIGN = {
    method = { '?one_of', { 'GET', 'PUT' } },
    expires = '?integer',
}

---@class TntS3CallOptions Настройки обращения
---@field timeout number|nil Срок вызова, секунд; по умолчанию срок драйвера
---@field idempotent boolean|nil Можно ли повторять после отправки; по умолчанию да

---@class TntS3PutOptions: TntS3CallOptions Настройки записи
---@field content_type string|nil Вид содержимого; по умолчанию application/octet-stream
---@field metadata table<string, string>|nil Пользовательские сведения: x-amz-meta-*

---@class TntS3ListOptions: TntS3CallOptions Настройки списка
---@field prefix string|nil Начало ключей
---@field delimiter string|nil Разделитель: ключи до него сворачиваются в prefixes
---@field after string|nil Метка продолжения: next прошлой страницы
---@field limit integer|nil Сколько объектов на странице, 1–1000; по умолчанию 1000

---@class TntS3PresignOptions Настройки ссылки с подписью
---@field method string|nil GET (по умолчанию) либо PUT
---@field expires integer|nil Сколько секунд ссылка годна, 1–604800; по умолчанию 900

---@class TntS3Stored Что записано
---@field etag string|nil Метка содержимого без кавычек
---@field version string|nil Версия из `x-amz-version-id`, если служба прислала; иная присылает её и в ведре без версий

---@class TntS3Client
---@field name string Имя драйвера
---@field bucket string Ведро
---@field features { transaction: boolean } Что драйвер умеет по договору
---@field settings TntS3Settings
---@field http TntHttpClient Клиент HTTP: свой кэш соединений libcurl
---@field retry TntRetry Повторы
---@field closed boolean Закрыт ли драйвер
local Client = {}
Client.__index = Client

--- Кладёт файл объектом кусками: файл меньше части — одним PUT, больше —
--- загрузкой частями (`tnt.s3.transfer`).
Client.put_file = transfer.put_file

--- Забирает объект в файл кусками с подменой файла в конце
--- (`tnt.s3.transfer`).
Client.get_file = transfer.get_file

--- Заводит драйвер. В сеть не ходит: первое обращение сделает первый вызов.
---@param opts TntS3Options
---@return TntS3Client
function Module.new(opts)
    local settings = settings_of.check(opts)
    local retries = settings.retry

    local retrier, wrong = retry.new({
        scope = settings.name,
        attempts = retries.attempts,
        base = retries.base,
        factor = retries.factor,
        jitter = retries.jitter,
        max = retries.max,
    })

    if retrier == nil then
        -- Отказ повторов сам начинается словами «настройки повторов»,
        -- и своя приставка назвала бы те же настройки дважды.
        error(wrong, 2)
    end

    -- Настройки клиента HTTP собраны из проверенных, и отказать он не может.
    -- Срок клиента — потолок драйвера: каждое обращение режет его остатком
    -- своего вызова. Переходов нет: подпись привязана к узлу, и переход
    -- S3 (301 на другую область) — ответ, который надо прочитать, а не
    -- пройти. Сжатие не просится: тело объекта — байты как записаны.
    local client = assert(http.new({
        timeout = settings.limits.max_timeout,
        max_redirects = 0,
        max_body = settings.max_bytes,
        max_connections = settings.http.max_connections,
        verify = settings.http.verify,
        ca_file = settings.http.ca_file,
        ca_path = settings.http.ca_path,
        accept_encoding = 'identity',
        user_agent = USER_AGENT,
        retry = { attempts = 1 },
    }))

    return setmetatable({
        name = settings.name,
        bucket = settings.bucket,
        features = { transaction = false },
        settings = settings,
        http = client,
        retry = retrier,
        closed = false,
    }, Client)
end

--- Кладёт объект целиком.
---
--- Повтор после обрыва — по умолчанию да: PUT того же тела даёт тот же
--- объект. В ведре с версиями повтор может оставить лишнюю версию;
--- кому это важно, ставит `idempotent = false`.
---@param key string Ключ объекта
---@param body string Тело
---@param opts TntS3PutOptions|nil
---@return TntS3Stored|nil stored Метка содержимого и версия
---@return TntStorageFailure|nil err
function Client:put(key, body, opts)
    call.check_key(key, 2)

    local timeout, idempotent = call.options(self, opts, PUT, 2)
    local headers = call.put_headers(opts or {}, 2)

    must.at(2).string(body, 'тело')

    return call.store(self, key, body, timeout, idempotent, headers)
end

--- Забирает объект.
---@param client TntS3Client
---@param method string GET либо HEAD
---@param key any
---@param opts table|nil
---@param level integer
---@return TntHttpResponse|nil answer Ответ 2xx; промах — nil без отказа
---@return TntStorageFailure|nil err
local function fetch(client, method, key, opts, level)
    call.check_key(key, level + 1)

    local timeout, idempotent = call.options(client, opts, call.CALL, level + 1)
    local asked = call.object(client, method, key)

    asked.miss = true

    local answer, err = call.run(client, asked, timeout, idempotent)

    if answer == nil or answer.status == call.NOT_FOUND then
        return nil, err
    end

    return answer
end

--- Забирает объект целиком.
---
--- Объекта нет — `nil` без отказа. Тело больше `max_bytes` — отказ
--- `rejected`: libcurl к этому мигу тело уже принял, предел бережёт тех,
--- кто работает с ответом дальше. Большое читают кусками — `reader`.
---@param key string
---@param opts TntS3CallOptions|nil
---@return string|nil body Тело; nil — объекта нет либо отказ
---@return TntS3Info|TntStorageFailure|nil info Сведения об объекте либо отказ
function Client:get(key, opts)
    local answer, err = fetch(self, 'GET', key, opts, 2)

    if answer == nil then
        return nil, err
    end

    return answer.body, reply.info(answer.headers, #answer.body)
end

--- Сведения об объекте без тела.
---@param key string
---@param opts TntS3CallOptions|nil
---@return TntS3Info|nil info Сведения; nil — объекта нет либо отказ
---@return TntStorageFailure|nil err
function Client:head(key, opts)
    local answer, err = fetch(self, 'HEAD', key, opts, 2)

    if answer == nil then
        return nil, err
    end

    return reply.info(answer.headers)
end

--- Удаляет объект.
---
--- Объекта нет — тоже `true`: так отвечает сам S3, и удаление, повторённое
--- после обрыва, не превращается в отказ.
---@param key string
---@param opts TntS3CallOptions|nil
---@return true|nil ok
---@return TntStorageFailure|nil err
function Client:delete(key, opts)
    call.check_key(key, 2)

    local timeout, idempotent = call.options(self, opts, call.CALL, 2)

    -- Удаление промаха не знает: 404 у DELETE — это нет ведра.
    local answer, err = call.run(self, call.object(self, 'DELETE', key), timeout, idempotent)

    if answer == nil then
        return nil, err
    end

    return true
end

--- Копирует объект внутри ведра силами службы: байты через узел не идут.
---
--- Вид содержимого и сведения переходят к копии от источника. Нет
--- источника — отказ `rejected` с `server_code = 'NoSuchKey'`: копия —
--- запись, и промаха у неё не бывает. Одной копией S3 берёт объект
--- не больше 5 ГБ.
---@param from string Ключ источника
---@param to string Ключ копии
---@param opts TntS3CallOptions|nil
---@return TntS3Stored|nil stored Метка содержимого и версия копии
---@return TntStorageFailure|nil err
function Client:copy(from, to, opts)
    call.check_key(from, 2, 'откуда')
    call.check_key(to, 2, 'куда')

    local timeout, idempotent = call.options(self, opts, call.CALL, 2)
    local source = self.settings.root .. sign.path('/' .. from)

    -- Путь источника — от ведра, даже при адресации ведра именем узла:
    -- заголовок называет ведро и ключ, а узел у копии и источника один.
    if self.settings.root == '' then
        source = ('/%s%s'):format(self.bucket, source)
    end

    local copied = call.object(self, 'PUT', to, { ['x-amz-copy-source'] = source })

    copied.confirm = true

    local answer, err = call.run(self, copied, timeout, idempotent)

    if answer == nil then
        return nil, err
    end

    return reply.confirmed(answer.body, answer.headers)
end

--- Страница списка объектов: по порядку ключей, не больше `limit`.
---
--- Продолжение — `after = page.next`: метка S3 несёт место, с которого
--- идти, и объекты, записанные между страницами, не сдвигают её.
---@param opts TntS3ListOptions|nil
---@return TntS3Page|nil page
---@return TntStorageFailure|nil err
function Client:list(opts)
    local timeout, idempotent = call.options(self, opts, LIST, 2)
    local given = opts or {}
    local limit = given.limit or Module.MAX_LIST

    must.at(2).between(limit, 'limit', 1, Module.MAX_LIST)

    local settings = self.settings
    ---@type table<string, string|nil>
    local params = {
        ['list-type'] = '2',
        ['max-keys'] = tostring(limit),
        prefix = given.prefix,
        delimiter = given.delimiter,
        ['continuation-token'] = given.after,
    }
    local listed = {
        method = 'GET',
        path = settings.root == '' and '/' or settings.root,
        query = sign.query(params),
        headers = { host = settings.host },
        payload = hash.digest('sha256', ''),
        shown = settings.where,
    }
    local answer, err = call.run(self, listed, timeout, idempotent)

    if answer == nil then
        return nil, err
    end

    return reply.page(answer.body)
end

--- Ссылка с подписью: по ней объект заберёт (GET) или положит (PUT)
--- тот, у кого ключа доступа нет, — браузер, чужая программа.
---
--- В сеть не ходит. Ссылка годна `expires` секунд с мига подписи,
--- и отозвать её нельзя: выдают её на короткий срок.
---@param key string
---@param opts TntS3PresignOptions|nil
---@return string|nil url
---@return TntStorageFailure|nil err
function Client:presign(key, opts)
    call.check_key(key, 2)
    must.at(2).optional.options(opts, 'настройки ссылки', PRESIGN)

    local given = opts or {}
    local expires = given.expires or Module.DEFAULT_EXPIRES

    must.at(2).between(expires, 'expires', 1, Module.MAX_EXPIRES)

    if self.closed then
        return nil, call.closed(self)
    end

    local settings = self.settings
    local path = settings.root .. sign.path('/' .. key)
    local query = sign.presign(settings.credentials, {
        method = given.method or 'GET',
        path = path,
        host = settings.host,
    }, call.stamp(), expires)

    return ('%s%s?%s'):format(settings.origin, path, query)
end

--- Открывает объект на чтение кусками: запрос с `Range` на каждый кусок
--- (`tnt.s3.download`). Нет объекта — `nil` без отказа.
---@param key string
---@param opts TntS3ReaderOptions|nil
---@return TntS3Download|nil reader
---@return TntStorageFailure|nil err
function Client:reader(key, opts)
    -- Не хвостовым вызовом: хвостовой снял бы этот кадр со стека, и бросок
    -- проверки назвал бы место на кадр выше вызывающего.
    local reader, err = download.open(self, key, opts, 2)

    return reader, err
end

--- Открывает запись объекта кусками: загрузка частями
--- (`tnt.s3.upload`). В сеть не ходит, пока не наберётся первая часть.
---@param key string
---@param opts TntS3WriterOptions|nil
---@return TntS3Upload writer
function Client:writer(key, opts)
    -- Не хвостовым вызовом — по той же причине, что у `reader`.
    local writer = upload.open(self, key, opts, 2)

    return writer
end

--- Закрывает драйвер: вызовы после — пара `closed`.
---
--- Соединений у драйвера своих нет — их держит libcurl, — поэтому
--- закрытие только отмечает драйвер. Повторное закрытие — пара `closed`,
--- а не исключение: закрытие при остановке узла гонится с запросами.
---@return boolean ok
---@return TntStorageFailure|nil err
function Client:close()
    if self.closed then
        return false, call.closed(self)
    end

    self.closed = true

    return true
end

--- Что настроено, без учётных данных.
---@return table
function Client:stats()
    return {
        name = self.name,
        where = self.settings.where,
        region = self.settings.credentials.region,
        closed = self.closed,
        retry = self.retry:status(),
    }
end

return Module
