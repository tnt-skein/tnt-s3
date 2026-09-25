--- Что ответил S3: сведения об объекте, страница списка, слова отказа.
---
--- Сведения об объекте приходят двумя путями: у `head` и `get` —
--- заголовками ответа, у `list` — полями XML. Виды записи у них разные
--- (время — HTTP-дата против ISO 8601, `ETag` в кавычках и в `&quot;`),
--- а наружу уходит один вид: время — `datetime`, `etag` — без кавычек.
--- Иначе вызывающий сравнивал бы `etag` из списка с `etag` из `head`
--- и не находил совпадения там, где объект тот же.

local date = require('tnt.date')
local xml = require('tnt.s3.xml')

local Module = {}

--- Приставка заголовков пользовательских сведений.
local META = '^x%-amz%-meta%-(.+)$'

---@class TntS3Info Сведения об объекте
---@field size integer|nil Байт
---@field etag string|nil Метка содержимого без кавычек
---@field type string|nil Вид содержимого
---@field modified datetime|nil Когда записан, UTC
---@field version string|nil Версия из `x-amz-version-id`, если служба прислала; иная присылает её и в ведре без версий
---@field metadata table<string, string> Пользовательские сведения; имена строчными

---@class TntS3Item Объект в списке
---@field key string
---@field size integer|nil
---@field etag string|nil
---@field modified datetime|nil

---@class TntS3Page Страница списка
---@field items TntS3Item[] Объекты по порядку ключей
---@field prefixes string[] Общие начала ключей до разделителя
---@field next string|nil Метка продолжения: `after` следующей страницы; nil — страниц больше нет

--- Метка содержимого без кавычек: в заголовке и в XML она в них.
---@param etag string|nil
---@return string|nil
local function unquoted(etag)
    if etag == nil or #etag < 2 or etag:find('^"') == nil or etag:find('"$') == nil then
        return etag
    end

    return etag:sub(2, -2)
end

--- Время из записи; негодная — пусто, а не отказ: сведения об объекте
--- не должны теряться из-за вида одного поля.
---@param parse fun(text: string): datetime|nil, string|nil
---@param text string|nil
---@return datetime|nil
local function moment(parse, text)
    if text == nil then
        return nil
    end

    return (parse(text))
end

--- Сведения об объекте из заголовков ответа.
---@param headers table<string, string> Заголовки; имена строчными
---@param size integer|nil Размер тела, если оно принято: он точнее заголовка
---@return TntS3Info
function Module.info(headers, size)
    local metadata = {}

    for name, value in pairs(headers) do
        local key = name:match(META)

        if key ~= nil then
            metadata[key] = value
        end
    end

    return {
        size = size or tonumber(headers['content-length']),
        etag = unquoted(headers.etag),
        type = headers['content-type'],
        modified = moment(date.parse_http, headers['last-modified']),
        version = headers['x-amz-version-id'],
        metadata = metadata,
    }
end

--- Страница списка из ответа `ListObjectsV2`.
---@param body string
---@return TntS3Page
function Module.page(body)
    local items = {}

    for index, block in ipairs(xml.blocks(body, 'Contents')) do
        items[index] = {
            key = xml.text(block, 'Key'),
            size = tonumber(xml.text(block, 'Size')),
            etag = unquoted(xml.text(block, 'ETag')),
            modified = moment(date.parse_iso, xml.text(block, 'LastModified')),
        }
    end

    local prefixes = {}

    for index, block in ipairs(xml.blocks(body, 'CommonPrefixes')) do
        prefixes[index] = xml.text(block, 'Prefix')
    end

    local next_token = nil

    -- Метка продолжения без признака обрыва не значит ничего: MinIO
    -- пишет её пустой и на последней странице.
    if xml.text(body, 'IsTruncated') == 'true' then
        next_token = xml.text(body, 'NextContinuationToken')
    end

    return { items = items, prefixes = prefixes, next = next_token }
end

--- Опознаватель начатой загрузки частями из ответа на её начало.
---@param body string
---@return string|nil
function Module.upload_id(body)
    return xml.text(body, 'UploadId')
end

--- Что записано действием, которое подтверждает итог телом: копией
--- объекта и завершением загрузки частями.
---
--- Метка содержимого у них — в теле, а версия — в заголовке, как у PUT.
---@param body string
---@param headers table<string, string>
---@return TntS3Stored
function Module.confirmed(body, headers)
    return { etag = unquoted(xml.text(body, 'ETag')), version = headers['x-amz-version-id'] }
end

--- Код и слова отказа из тела ответа; нет их — пусто.
---
--- У HEAD тела нет вовсе, у прокси перед S3 — своя страница: код тогда
--- называет только статус ответа.
---@param body string
---@return string|nil code `NoSuchKey`, `AccessDenied`, `SlowDown`…
---@return string|nil message
function Module.fault(body)
    -- Нет блока — читать из пустоты: оба поля выйдут пустыми сами, без
    -- отдельной ветки, у которой `return nil, nil` и `return nil` неотличимы.
    local block = xml.blocks(body, 'Error')[1] or ''

    return xml.text(block, 'Code'), xml.text(block, 'Message')
end

return Module
