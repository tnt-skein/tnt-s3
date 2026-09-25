# tnt-s3

Клиент S3 для Tarantool: подпись запросов AWS Signature Version 4,
объект целиком и кусками — чтение по диапазону и загрузка частями, —
копия силами службы, список, ссылки с подписью и файлы поверх `tnt-http`,
на файберах. Драйвер привязан к одному ведру, срок один на вызов,
повторяет сам драйвер, отказ — пара `nil, err` с родом по коду ответа
службы.

```lua
local s3 = require('tnt.s3')

local bucket = s3.new({ endpoint = 'https://s3.eu-central-1.amazonaws.com', region = 'eu-central-1',
    bucket = 'backups', access_key = key_id, secret_key = secret })

local stored, err = bucket:put('reports/2026-09.csv', text, { content_type = 'text/csv' })
local body, info = bucket:get('reports/2026-09.csv')              -- нет объекта — nil без err
local page = bucket:list({ prefix = 'reports/', limit = 100 })    -- дальше — after = page.next
local link = bucket:presign('reports/2026-09.csv', { expires = 600 })
bucket:put_file('snapshots/00000042.snap', '/var/lib/tarantool/00000042.snap')
```

Зависимости: `tnt-must` (проверки аргументов), `tnt-clock` (часы
подписи), `tnt-date` (время из ответа), `tnt-fs` (файлы), `tnt-hash`
(HMAC и свёртки), `tnt-http` (запросы через libcurl со своим кэшем
соединений), `tnt-retry` (повторы), `tnt-external` (подмена часов
в проверках) и `tnt-storage` (срок и отказ с родом).

## Зачем

Готового клиента S3 у Tarantool нет ни в ядре, ни среди официальных
роков, а клиенты с luarocks.org ходят в сеть мимо файберов и вешают узел
целиком. Своего в пакете немного — подпись и чтение ответов, — и оно
закрывает места, где голый HTTP подводит молча:

- **Подписывается ровно то, что уходит**: путь и строку параметров
  кодирует тот же кодировщик, что у клиента HTTP, и они же уходят
  в адрес — второго кодировщика, который однажды закодирует иначе, нет.
  Пять примеров подписи из документации AWS сходятся дословно.
- **Сведения об объекте одного вида** у `get`, `head` и в списке, хотя
  S3 отдаёт их заголовками и XML: время — `datetime` в UTC, метка
  содержимого — без кавычек.
- **Промах — `nil` без отказа**, а нет ведра — отказ: это настройка,
  а не промах. Удаление того, чего нет, — `true`.
- **Отказ — пара `nil, err` с родом** (`unreachable`, `denied`, `busy`,
  `conflict`, `timeout`, `broken`, `rejected`, `closed`), признаком
  отправки и приговором повтору; код S3 — в `server_code`.
- **Все действия идемпотентны** — GET, HEAD, PUT, DELETE, — поэтому обрыв
  после отправки повторяется без просьбы, и каждая попытка
  подписывается заново.
- **Ключ с отрезком `..` до службы не доходит**: libcurl свернул бы
  `a/../b` в `b`, и запрос ушёл бы в чужой объект.

## Установка

```sh
tt rocks install tnt-s3 --server=https://tnt-skein.github.io/rocks
```

Или из исходников:

```sh
git clone https://github.com/tnt-skein/tnt-s3.git
cd tnt-s3 && tt rocks make
```

## Как пользоваться

| Вызов | Что отдаёт |
|---|---|
| `s3.new(opts)` | драйвер; в сеть не ходит; негодная или незнакомая настройка — исключение |
| `put(key, body, opts)` | `{ etag, version }` — записан объект целиком |
| `get(key, opts)` | тело и сведения; нет объекта — `nil` без отказа |
| `head(key, opts)` | сведения без тела; нет объекта — `nil` |
| `delete(key, opts)` | `true`; объекта не было — тоже `true` |
| `list(opts)` | страница: `items`, `prefixes`, `next` |
| `presign(key, opts)` | ссылка с подписью на GET или PUT; в сеть не ходит |
| `copy(from, to, opts)` | `{ etag, version }` копии; копирует служба |
| `reader(key, opts)` | читатель кусками: запрос с `Range` и `If-Match` на кусок |
| `writer(key, opts)` | писатель кусками: загрузка частями, объект встаёт в `finish` |
| `put_file(key, path, opts)`, `get_file(key, path, opts)` | файл в объект и объект в файл кусками, файл подменяется атомарно |
| `close()`, `stats()` | закрыть; что настроено — без учётных данных |

Настройки драйвера: `endpoint` (`http(s)://узел[:порт]`, без пути),
`bucket`, `access_key`, `secret_key`, `session_token`, `region`
(`us-east-1`), `addressing` (`path` либо `host`), `timeout`
и `max_timeout` (5 и 60 с), `max_bytes` (16 МБ), `verify`, `ca_file`,
`ca_path`, `max_connections`, `retry` (как у `tnt-retry`), `name`.
У каждого вызова, кроме `presign`, — `timeout` и `idempotent`; у `put`,
`writer` и `put_file` ещё `content_type` и `metadata`, у `writer`
и `put_file` — `part_size` (8 МБ), у `reader` и `get_file` — `piece`
(8 МБ), у `list` — `prefix`, `delimiter`, `limit` и `after`,
у `presign` — `method` и `expires`.

```lua
-- Обход ведра страницами: метка продолжения не сдвигается от записей
-- между страницами.
local page, err = bucket:list({ prefix = 'журнал/', limit = 1000 })

while page ~= nil do
    -- … обработать page.items …
    if page.next == nil then
        break
    end

    page, err = bucket:list({ prefix = 'журнал/', limit = 1000, after = page.next })
end

-- Ссылка для загрузки браузером: подписан только узел, вид содержимого
-- ставит тот, кто кладёт.
local upload = bucket:presign('выгрузки/отчёт.pdf', { method = 'PUT', expires = 60 })
```

## Проверки

```sh
make deps            # luatest, luacheck, luacov с cluacov и зависимости пакета в .rocks
make check           # форматирование, линт, проверки, покрытие с порогом 100 %
make mutants-all     # мутационное тестирование утилитой tnt-mutants из PATH, порог 100 % убитых
make s3-up           # Garage в докере для живых проверок; make s3-down — погасить
```

Покрытие строк — 100 %, убитых мутантов — 100 % (104 проверки,
815 мутантов в девяти модулях). Что уходит на сервер, проверяется
на настоящем `tnt-http` с двойником libcurl; две проверки идут
на настоящем libcurl против сервера на сокете Tarantool, а девять живых —
против Garage стенда; без поднятой службы они пропускаются.

## Документ

Полное описание с настройками, сведениями об объекте, списком, ссылками,
файлами, отказами, сроком, повторами, подписью, журналом и обоснованием
решений: [docs/s3.md](docs/s3.md).

## Лицензия

MIT.
