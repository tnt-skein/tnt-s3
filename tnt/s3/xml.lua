--- Чтение ответов S3: список ключей, отказ, итог загрузки.
---
--- Разбора XML в Tarantool нет — ни в ядре, ни среди официальных роков, —
--- а ответы S3 устроены просто: элементы без атрибутов, без CDATA и без
--- вложенных элементов с тем же именем там, где их читают. Поэтому здесь
--- не разборщик XML, а чтение известных элементов по имени: блоки
--- (`Contents`, `CommonPrefixes`) — списком, поля в блоке — текстом.
---
--- Чего это чтение не умеет, и это решение: атрибутов, пространств имён
--- в именах элементов, комментариев между полями и CDATA. S3 и MinIO
--- ничего из этого в своих ответах не пишут; чужой ответ, в котором
--- они есть, прочитается не целиком, а не уронит узел.
---
--- Текст элемента раскрывается: пять именованных сущностей XML и числовые
--- ссылки `&#N;`, `&#xH;` — S3 пишет ими знаки ключа, которых XML 1.0
--- не несёт как есть.

local utf8 = require('utf8')

local Module = {}

--- Именованные сущности XML 1.0.
---@type table<string, string>
local ENTITIES = { lt = '<', gt = '>', amp = '&', quot = '"', apos = "'" }

--- Число числовой ссылки по её записи: десятичной либо `x` и шестнадцатеричной.
---
--- Разбирает `tonumber` с основанием, а не образец с `%d+`: запись без
--- цифр он и так не примет, а у образца мутант `%d*` был бы неотличим.
---@param body string Запись без `&#` и `;`
---@return number|nil
local function code_of(body)
    if body:find('^[xX]') ~= nil then
        return tonumber(body:sub(2), 16)
    end

    return tonumber(body, 10)
end

--- Знак по числовой ссылке в UTF-8; ссылка вне Юникода и нулевой знак
--- остаются как были.
---@param body string
---@return string|nil
local function numeric(body)
    local code = code_of(body)

    if code == nil or code < 1 or code > 0x10FFFF then
        return nil
    end

    return utf8.char(code)
end

--- Одна сущность: `&имя;` либо `&#число;` целиком.
---@param whole string
---@return string|nil
local function entity(whole)
    local body = whole:sub(2, -2)

    if body:find('^#') == nil then
        return ENTITIES[body]
    end

    return numeric(body:sub(2))
end

--- Раскрывает сущности в тексте элемента.
---
--- Незнакомая сущность остаётся как есть: разбор ответа не должен
--- отказывать из-за того, что сервер написал больше, чем мы знаем.
--- Сущность ищется парой `&…;` (`%b`), без повторов в образце: у S3
--- голого `&` в тексте не бывает, а пустая сущность `&;` ничего не значит.
---@param text string
---@return string
function Module.decode(text)
    return (text:gsub('%b&;', entity))
end

--- Текст первого элемента с этим именем, раскрытый; нет элемента — nil.
---
--- Пустой элемент бывает и парой тегов, и одним `<Имя/>`: S3 пишет
--- `<Prefix></Prefix>`, MinIO — иногда `<Prefix/>`.
---@param document string
---@param name string Имя элемента
---@return string|nil
function Module.text(document, name)
    local inner = document:match(('<%s>(.-)</%s>'):format(name, name))

    if inner ~= nil then
        return Module.decode(inner)
    end

    -- Образцом, а не простым поиском: имя элемента — буквы, и знаков
    -- образца в `<Имя/>` нет, а аргументы простого поиска давали бы мутантов,
    -- неотличимых от него самого.
    if document:find(('<%s/>'):format(name)) ~= nil then
        return ''
    end

    return nil
end

--- Все блоки с этим именем, по порядку: их внутренности как есть.
---@param document string
---@param name string Имя элемента
---@return string[]
function Module.blocks(document, name)
    local found = {}

    for inner in document:gmatch(('<%s>(.-)</%s>'):format(name, name)) do
        table.insert(found, inner)
    end

    return found
end

return Module
