--- Настройки драйвера S3: умолчания и проверка.
---
--- Проверяется всё и сразу, в `s3.new`: драйвер заводят при подъёме узла,
--- а первый запрос шлют через час под нагрузкой. Негодная настройка —
--- исключение на строке того, кто завёл драйвер, незнакомый ключ — тоже:
--- опечатка `secret_kye` иначе молча оставила бы драйвер без ключа.
---
--- Сроки проверяет `tnt-storage` (`within.settings`): умолчание 5 с,
--- потолок `max_timeout` 60 с — одно правило на все драйверы. Границы
--- повторов проверяет сам `tnt-retry`.

local must = require('tnt.must')
local within = require('tnt.storage.within')

local Module = {}

--- Область по умолчанию: её же берёт MinIO, когда область не задана.
Module.DEFAULT_REGION = 'us-east-1'

--- Как адресуется ведро по умолчанию: путём.
---
--- Путь работает у всех — AWS, MinIO, Ceph, облаков с S3 — и с любым
--- именем ведра, а адрес с ведром в имени узла (`host`) ломает проверку
--- сертификата на ведре с точкой в имени: `*.s3.amazonaws.com` покрывает
--- одно слово, а не два.
Module.PATH = 'path'

--- Ведро в имени узла: `ведро.узел`.
Module.HOST = 'host'

--- Предел байтов ответа по умолчанию: 16 МБ.
---
--- Ответ `tnt-http` принимает целиком, строкой, и объект на гигабайт
--- занял бы память узла, в которой живут его данные.
--- Кому нужно больше, поднимает предел и знает, что делает.
Module.DEFAULT_MAX_BYTES = 16 * 1024 * 1024

--- Имя драйвера по умолчанию: в отказах и в ведре повторов.
Module.DEFAULT_NAME = 's3'

--- Уровень вины: строка того, кто завёл драйвер.
---
--- `check` зовёт `s3.new` не хвостовым вызовом: уровень 2 — строка
--- в `s3.lua`, 3 — строка вызывающего.
local OWNER = 3

--- Проверки с виной на строке того, кто завёл драйвер.
local owner = must.at(OWNER)

--- Как настройки называются в отказе.
local TITLE = 'настройки s3'

--- Настройки повторов, которые драйвер передаёт `tnt-retry` как есть.
---
--- Срока (`deadline`) и суждения о повторе (`retriable`) здесь нет: срок —
--- у каждого вызова свой, а судит поле `retriable` отказа.
local RETRY = {
    attempts = '?integer',
    base = '?number',
    factor = '?number',
    jitter = '?number|string',
    max = '?number',
}

--- Все настройки драйвера. Незнакомый ключ — отказ.
local OPTIONS = {
    endpoint = 'not_empty',
    region = '?not_empty',
    bucket = 'not_empty',
    access_key = 'not_empty',
    secret_key = 'not_empty',
    session_token = '?not_empty',
    addressing = { '?one_of', { Module.PATH, Module.HOST } },
    timeout = '?number',
    max_timeout = '?number',
    max_bytes = '?integer',
    verify = '?boolean',
    ca_file = '?not_empty',
    ca_path = '?not_empty',
    max_connections = '?integer',
    retry = { '?options', RETRY },
    name = '?not_empty',
}

---@class TntS3Options
---@field endpoint string Адрес службы: `https://s3.eu-central-1.amazonaws.com`, `http://minio:9000`
---@field region string|nil Область; по умолчанию us-east-1
---@field bucket string Ведро
---@field access_key string Опознаватель ключа
---@field secret_key string Секрет ключа
---@field session_token string|nil Временный токен STS
---@field addressing string|nil Как адресуется ведро: path (по умолчанию) либо host
---@field timeout number|nil Срок вызова по умолчанию, секунд; 5
---@field max_timeout number|nil Потолок срока вызова, секунд; 60
---@field max_bytes integer|nil Предел байтов ответа; 16 МБ
---@field verify boolean|nil Проверять ли сертификат сервера; по умолчанию да
---@field ca_file string|nil Файл доверенных корней
---@field ca_path string|nil Каталог доверенных корней
---@field max_connections integer|nil Размер кэша соединений libcurl
---@field retry table|nil Настройки повторов: attempts, base, factor, jitter, max
---@field name string|nil Имя драйвера; s3

---@class TntS3Settings
---@field name string
---@field bucket string
---@field where string Ведро на узле — начало текста отказа, без учётных данных
---@field origin string Схема и узел, куда уходят запросы: `http://minio:9000`
---@field host string Заголовок host: узел либо `ведро.узел`
---@field root string Путь ведра: `/ведро` либо пусто
---@field credentials TntS3Credentials
---@field limits TntStorageLimits Сроки вызова
---@field max_bytes integer
---@field http table Настройки `tnt-http`: проверка сертификата и кэш соединений
---@field retry table Настройки повторов как даны

--- Схема и узел адреса службы; иное — исключение.
---
--- Бросок — на кадр глубже `check`: эту функцию зовёт он.
---
--- Путь в адресе службы не принимается: подпись считается по пути,
--- который дошёл до S3, а прокси с приставкой пути его переписывает, —
--- такой адрес давал бы отказ подписи на каждом запросе.
---@param endpoint string
---@return string scheme
---@return string authority
local function split(endpoint)
    local lowered = endpoint:lower()
    local scheme = nil

    if lowered:find('^https://') ~= nil then
        scheme = 'https'
    elseif lowered:find('^http://') ~= nil then
        scheme = 'http'
    end

    -- Узел — всё после `://`: схема и три знака разделителя.
    local authority = scheme and endpoint:sub(#scheme + 4):match('^([^/?#@]+)/?$')

    if authority == nil then
        error(
            ('%s.endpoint — адрес вида http(s)://узел[:порт] без пути, а не «%s»'):format(
                TITLE,
                endpoint
            ),
            OWNER + 1
        )
    end

    ---@cast scheme string
    return scheme, authority
end

--- Имя ведра по правилам S3: 3–63 знака, строчные латинские буквы, цифры,
--- точки и дефисы, по краям — буква либо цифра.
---
--- Правила строже, чем принял бы путь: ведро с прописной буквой или
--- подчёркиванием AWS заводил только в us-east-1 до 2018 года, а в имени
--- узла (`addressing = 'host'`) оно не живёт вовсе.
---@param bucket string
local function check_bucket(bucket)
    -- Знаки и края — порознь, без повтора в образце: у `[…]*` мутант `[…]+`
    -- отличался бы только на двух знаках, а их отсекает длина.
    local wrong = bucket:find('[^a-z0-9.%-]') ~= nil or bucket:find('^[.%-]') ~= nil or bucket:find('[.%-]$') ~= nil

    if #bucket < 3 or #bucket > 63 or wrong then
        error(
            (
                '%s.bucket — 3–63 знака: строчные латинские буквы, цифры, точки и дефисы, '
                .. 'по краям буква либо цифра, а не «%s»'
            ):format(TITLE, bucket),
            OWNER + 1
        )
    end
end

--- Проверяет настройки и дополняет их умолчаниями.
---@param opts TntS3Options|nil
---@return TntS3Settings
function Module.check(opts)
    owner.options(opts, TITLE, OPTIONS)

    ---@cast opts TntS3Options
    local scheme, authority = split(opts.endpoint)

    check_bucket(opts.bucket)
    owner.optional.positive(opts.max_bytes, TITLE .. '.max_bytes')
    owner.optional.positive(opts.max_connections, TITLE .. '.max_connections')

    local region = opts.region or Module.DEFAULT_REGION
    local host = authority
    local root = '/' .. opts.bucket

    if opts.addressing == Module.HOST then
        host = ('%s.%s'):format(opts.bucket, authority)
        root = ''
    end

    return {
        name = opts.name or Module.DEFAULT_NAME,
        bucket = opts.bucket,
        where = ('%s/%s'):format(authority, opts.bucket),
        origin = ('%s://%s'):format(scheme, host),
        host = host,
        root = root,
        credentials = {
            access_key = opts.access_key,
            secret_key = opts.secret_key,
            session_token = opts.session_token,
            region = region,
        },
        limits = within.settings(opts.timeout, opts.max_timeout, OWNER),
        max_bytes = opts.max_bytes or Module.DEFAULT_MAX_BYTES,
        http = {
            verify = opts.verify,
            ca_file = opts.ca_file,
            ca_path = opts.ca_path,
            max_connections = opts.max_connections,
        },
        retry = opts.retry or {},
    }
end

return Module
