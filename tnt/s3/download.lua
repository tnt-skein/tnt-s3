--- Чтение объекта кусками: по запросу с диапазоном (`Range`) на кусок.
---
---     local reader, err = bucket:reader('exports/2026-09.csv')   -- нет объекта — nil без err
---
---     while true do
---         local chunk, failure = reader:read()
---
---         if chunk == nil then
---             return failure == nil, failure
---         end
---
---         send(chunk)
---     end
---
--- Клиент HTTP отдаёт тело строкой, а поток у него копит тело, не дожидаясь
--- чтения: обратного давления у `http.client` нет. Поэтому объект читается
--- не одним потоком, а запросами за куском: `GET` с `Range: bytes=a-b`,
--- и в памяти узла лежит один кусок, сколько бы ни весил объект.
---
--- Открытие спрашивает сведения (`HEAD`): размер — чтобы знать, где конец,
--- метку содержимого — чтобы каждый кусок брался у того же объекта; пустой
--- объект так и не просится вовсе. Кусок
--- просится с `If-Match`, и объект, подменённый посреди чтения, — отказ
--- `conflict` (412), а не файл, склеенный из двух разных объектов.
---
--- Срок и повторы — у каждого куска свои: чтение большого объекта длится
--- столько, сколько длится, а одним сроком его не измерить.

local must = require('tnt.must')
local storage = require('tnt.storage')

local call = require('tnt.s3.call')
local reply = require('tnt.s3.reply')

local failure = storage.failure

local Module = {}

--- Кусок по умолчанию: 8 МБ, но не больше предела ответа драйвера.
---
--- Кусок меньше — больше обращений к службе на тот же объект: у S3 каждое
--- стоит и времени, и денег. Больше — больше памяти на каждого читателя.
Module.PIECE = 8 * 1024 * 1024

--- Настройки чтения.
local OPTIONS = { timeout = '?number', idempotent = '?boolean', piece = '?integer' }

---@class TntS3ReaderOptions: TntS3CallOptions Настройки чтения кусками
---@field piece integer|nil Сколько байт просить за раз; по умолчанию 8 МБ, не больше max_bytes драйвера

---@class TntS3Download Чтение объекта кусками
---@field key string Ключ объекта
---@field info TntS3Info Сведения об объекте на миг открытия
---@field client TntS3Client
---@field timeout number
---@field idempotent boolean
---@field piece integer
---@field size integer Размер объекта на миг открытия
---@field offset number С какого байта следующий кусок
---@field ended boolean Чтение кончилось: объект дочитан либо отказал
---@field closed boolean Закрыт вызывающим
---@field failure TntStorageFailure|nil Отказ, которым кончилось чтение
local Download = {}
Download.__index = Download

--- Промах `HEAD`, переспрошенный одним байтом.
---
--- У ответа на HEAD тела нет, и «нет ключа» от «нет ведра» не отличить.
--- `GET` первого байта отличает: `NoSuchKey` — промах, `NoSuchBucket` —
--- отказ, как у `get`. Нет ведра — настройка, а не промах, и чтение
--- с ошибкой в имени ведра не должно отвечать «объекта нет».
---@param client TntS3Client
---@param key string
---@param timeout number
---@param idempotent boolean
---@return nil
---@return TntStorageFailure|nil err
local function probe(client, key, timeout, idempotent)
    local asked = call.object(client, 'GET', key, { range = 'bytes=0-0' })

    asked.miss = true

    local _, err = call.run(client, asked, timeout, idempotent)

    return nil, err
end

--- Открывает объект на чтение кусками.
---
--- Нет объекта — `nil` без отказа, как у `get` и `head`.
---@param client TntS3Client
---@param key any
---@param opts TntS3ReaderOptions|nil
---@param level integer Уровень вины в кадрах того, кто зовёт
---@return TntS3Download|nil reader
---@return TntStorageFailure|nil err
function Module.open(client, key, opts, level)
    call.check_key(key, level + 1)

    local timeout, idempotent = call.options(client, opts, OPTIONS, level + 1)
    local limit = client.settings.max_bytes
    local piece = (opts or {}).piece or math.min(Module.PIECE, limit)

    must.at(level + 1).between(piece, 'piece', 1, limit)

    local head = call.object(client, 'HEAD', key)

    head.miss = true

    local answer, err = call.run(client, head, timeout, idempotent)

    if answer == nil then
        return nil, err
    end

    if answer.status == call.NOT_FOUND then
        return probe(client, key, timeout, idempotent)
    end

    local info = reply.info(answer.headers)
    local size = info.size

    -- Без размера не понять, где конец: кусок за концом служба отвергает
    -- (416), и чтение, идущее до отказа, выдало бы отказ за конец.
    if size == nil then
        return nil,
            failure.new(
                failure.BROKEN,
                ('HEAD %s: служба не назвала размер объекта'):format(head.shown),
                { idempotent = false }
            )
    end

    return setmetatable({
        key = key,
        info = info,
        size = size,
        client = client,
        timeout = timeout,
        idempotent = idempotent,
        piece = piece,
        offset = 0,
        ended = false,
        closed = false,
    }, Download)
end

--- Кончает чтение отказом: следующее чтение ответит им же.
---@param reader TntS3Download
---@param err any
---@return nil
---@return TntStorageFailure
local function fail(reader, err)
    reader.ended = true
    reader.failure = err

    return nil, err
end

--- Следующий кусок.
---
--- Исходы — как у читателя файла: кусок — непустая строка; `nil` без
--- отказа — объект кончился; `nil, err` — отказ, и чтение кончилось.
--- Читать после конца можно: вернётся то же, чем чтение кончилось.
---@return string|nil chunk
---@return TntStorageFailure|nil err
function Download:read()
    if self.closed then
        error(('read: читатель объекта %s уже закрыт'):format(self.key), 2)
    end

    local last = math.min(self.offset + self.piece, self.size) - 1

    -- Конец — когда следующему куску не осталось ни байта: у пустого
    -- объекта это сразу, и кусков он не просит.
    if self.ended or last < self.offset then
        return nil, self.failure
    end
    local headers = { range = ('bytes=%d-%d'):format(self.offset, last) }

    if self.info.etag ~= nil then
        headers['if-match'] = ('"%s"'):format(self.info.etag)
    end

    local piece = call.object(self.client, 'GET', self.key, headers)
    local answer, err = call.run(self.client, piece, self.timeout, self.idempotent)

    if answer == nil then
        return fail(self, err)
    end

    local expected = last - self.offset + 1

    -- Кусок не той длины — служба не поняла диапазон и прислала объект
    -- целиком либо оборвала тело: склеенный из такого файл вышел бы
    -- не тем объектом.
    if #answer.body ~= expected then
        return fail(
            self,
            failure.new(
                failure.BROKEN,
                ('GET %s: вместо %d байт с %d пришло %d'):format(
                    piece.shown,
                    expected,
                    self.offset,
                    #answer.body
                ),
                { idempotent = false }
            )
        )
    end

    self.offset = last + 1

    return answer.body
end

--- Закрывает читатель. Соединений он не держит — их держит libcurl, —
--- поэтому закрытие только запрещает читать дальше.
---@return true
function Download:close()
    self.closed = true

    return true
end

return Module
