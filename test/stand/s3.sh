#!/usr/bin/env bash
# Поднимает Garage для живых проверок драйвера tnt-s3.
#
# Настоящий сервер, а не двойник: двойник показывает, что мы правильно
# разговариваем сами с собой, а чужой сервер — что нашу подпись SigV4
# сверяет кто-то ещё. Разница вылезает на первом же ключе с пробелом,
# на заголовке host с портом и на отказе подписи.
#
# Один узел без второй копии данных: раскладку узла заводит сам сервер
# (`--single-node`), и шагов «назначить роль — применить раскладку»
# стенду не нужно. В контейнере заводятся ведро проверок, ключ с правами
# чтения и записи и ключ только для чтения — чтобы отказ AccessDenied
# был настоящим. Данные живут в контейнере и уходят вместе с ним.
#
# Каталог настройки — `STAND_S3_DIR`, по умолчанию `test/stand/run/s3`.
# Имя контейнера — `STAND_S3_CONTAINER`: второй стенд рядом с первым
# поднимается со своим именем и портом и первого не сносит.
#
#   test/stand/s3.sh          # поднять
#   test/stand/s3.sh stop     # погасить
set -euo pipefail

# Относительный каталог отсчитывается от места запуска — так его понимает
# тот, кто задал. Ниже сценарий переходит в свой каталог, и без этого
# стенд лёг бы не туда, куда просили.
case "${STAND_S3_DIR:-}" in
    '' | /*) ;;
    *) STAND_S3_DIR="${PWD}/${STAND_S3_DIR}" ;;
esac

cd "$(dirname "$0")"

# Выпуск закреплён и отпечатком: тег можно перевыложить, и живые проверки
# молча пошли бы против другого сервера.
IMAGE='dxflrs/garage:v2.4.1@sha256:9c96caa2612d3411acc5b0e6701fb238dbfba33e533a6d7d3d811a4b12d0d020'
CONTAINER="${STAND_S3_CONTAINER:-tnt-stand-s3}"
PORT="${STAND_S3_PORT:-19000}"
DIR="${STAND_S3_DIR:-run/s3}"
BUCKET='tnt-live'

# Ключи стенда: локальный сервер для проверок, а не развёртывание.
# Вид — как у ключей, которые выдаёт сам Garage: опознаватель — `GK`
# и 12 байт в hex (здесь байты строк `tnt-stand-rw` и `tnt-readonly`),
# секрет — 32 байта в hex (sha256 от `tnt-stand-secret`
# и `tnt-reader-secret`). Живые проверки зашивают те же значения.
STAND_KEY='GK746e742d7374616e642d7277'
STAND_SECRET='db299f3310a74ee703523bb4d3a6df11a031668814c5af9568008e879cc7106f'
READER_KEY='GK746e742d726561646f6e6c79'
READER_SECRET='b047f9d1b3f5b3da0c3a97983c6837cc4bcb9e98e09356708db69bc2e3768b64'

if ! command -v docker > /dev/null 2>&1; then
    echo 'docker не найден: Garage поднять нечем' >&2
    exit 1
fi

if [ "${1:-up}" = 'stop' ]; then
    docker rm -f "${CONTAINER}" > /dev/null 2>&1 || true
    echo 'Garage остановлен'
    exit 0
fi

# Средство управления — тот же исполняемый файл в контейнере. Журнал —
# с предупреждений: на уровне info каждый вызов пишет о рукопожатии
# с узлом, и в этом шуме тонет настоящий отказ.
garage() {
    docker exec -e RUST_LOG=garage=warn "${CONTAINER}" /garage "$@"
}

mkdir -p "${DIR}"
DIR="$(cd "${DIR}" && pwd)"

# Настройка — файлом, смонтированным только для чтения, а не heredoc
# внутри контейнера: в образе нет ничего, кроме /garage, — ни шелла,
# ни cat, — и записать файл изнутри нечем. Файл нужен не одному серверу:
# `garage` под `docker exec` берёт из него секрет и адрес RPC.
#
# Файл пишется заново на каждый подъём, и содержимое у него всегда одно
# и то же: второй стенд рядом переписывает его тем же текстом и первому
# не мешает.
cat > "${DIR}/garage.toml" << 'TOML'
# Одна копия данных: узел один, второй копии жить негде.
replication_factor = 1

# sqlite, а не lmdb по умолчанию: стенду не нужна скорость lmdb, а файл
# sqlite не зависит от того, как файловая система контейнера держит mmap.
db_engine = "sqlite"
metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"

# RPC не выходит из контейнера: порт не публикуется, а средство
# управления ходит к узлу изнутри. Поэтому и секрет постоянный:
# sha256 от `tnt-stand-rpc`.
rpc_bind_addr = "127.0.0.1:3901"
rpc_public_addr = "127.0.0.1:3901"
rpc_secret = "2cb7af1343b95c7d8c63cfd67818f99b3a6fc186ac92cbb50fe3b5d3ce564925"

[s3_api]
# Та область, которой драйвер подписывает по умолчанию: подпись с другой
# областью Garage не сверяет, а отвечает 400 AuthorizationHeaderMalformed.
s3_region = "us-east-1"
# IPv4: докер пробрасывает опубликованный порт по нему.
api_bind_addr = "0.0.0.0:3900"
TOML

# Повторный запуск безвреден: контейнер с тем же именем сносится
# и поднимается заново, с пустым ведром.
docker rm -f "${CONTAINER}" > /dev/null 2>&1 || true

docker run -d \
    --name "${CONTAINER}" \
    -p "127.0.0.1:${PORT}:3900" \
    -v "${DIR}/garage.toml:/etc/garage.toml:ro" \
    "${IMAGE}" \
    /garage server --single-node > /dev/null

# Готовности ждём: проверки, запущенные сразу после подъёма, иначе
# пропустятся — и это выглядит как «всё хорошо», хотя ничего
# не проверено. Порт S3 открывается раньше, чем заведены ключи, поэтому
# ждём не порта, а здоровья узла, и выходим, только когда ведро и ключи
# на месте.
for _ in $(seq 1 50); do
    if garage health > /dev/null 2>&1; then
        garage bucket create "${BUCKET}" > /dev/null
        # Импорт, а не `key create`: тот выдаёт случайные значения, которых
        # проверки не знают. `--yes` обязателен: импорт задуман для ключей,
        # которые Garage выдал сам, и без подтверждения он отказывает.
        garage key import --yes -n tnt-stand "${STAND_KEY}" "${STAND_SECRET}" > /dev/null
        garage key import --yes -n tnt-reader "${READER_KEY}" "${READER_SECRET}" > /dev/null
        garage bucket allow --read --write "${BUCKET}" --key "${STAND_KEY}" > /dev/null
        garage bucket allow --read "${BUCKET}" --key "${READER_KEY}" > /dev/null
        echo "Garage поднят: http://127.0.0.1:${PORT}, область us-east-1, ведро ${BUCKET}"
        exit 0
    fi

    sleep 0.2
done

echo "Garage не ответил за 10 секунд: смотрите docker logs ${CONTAINER}" >&2
exit 1
