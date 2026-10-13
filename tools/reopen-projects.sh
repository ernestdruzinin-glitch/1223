#!/bin/bash
# Заново открывает в приложении Claude проекты, чьи сессии удалились.
#
# Для каждого проекта создаёт новую сессию Claude Code в его собственной папке
# (а не в ~/Downloads/magicui-main). В первом ходе Claude читает отчёты-артефакты
# и код и пишет сводку: что сделано, что осталось, следующие шаги. Файлы он при этом
# не меняет. Потом сессия открывается в приложении Claude, где её можно продолжать.
#
# Запуск:   bash reopen-projects.sh                # все проекты
#           bash reopen-projects.sh site crm       # только выбранные
# Проекты:  site — сайт ohota-rybalka05.ru, SEO и реклама  (~/achikol-ohothozyaistvo)
#           bot  — Telegram-бот Growth OS                  (~/ohota-gos)
#           crm  — CRM охотхозяйства                       (~/ohota-crm)
#           game — игра «КОНСУМАЦИЯ»                        (~/konsumaciya)

set -u

ALL="site bot crm game"
SELECTED="${*:-$ALL}"
LOGDIR="$HOME/claude-reopen-$(date +%Y%m%d-%H%M%S)-$$"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PROJECTS_DIR="$CLAUDE_DIR/projects"
# Восстановленная игра в репозитории, на случай если исходного файла уже нет.
GAME_URL="https://raw.githubusercontent.com/ernestdruzinin-glitch/1223/babce759e920559ba36a8fd681e28f4f236a72fb/games/konsumaciya/index.html"

ART="https://claude.ai/artifact"
COMMON="Прошлые сессии по этому проекту удалились вместе с перепиской, это новая сессия вместо них.
Сначала прочитай отчёты по ссылкам выше инструментом Artifact (action read), если они есть.
Потом изучи код и файлы в этой папке. Ничего не меняй, ничего не запускай на сервере и не
выводи содержимое секретов (.env, ключи, keystore) — сейчас нужен только обзор.
В конце ответь коротко, по-русски:
1) что это за проект и как он устроен;
2) что из отчётов уже сделано, а что нет — сверь с кодом;
3) три следующих шага по важности.
Дальше жди моих указаний."

# Задаёт NAME, DIR и PROMPT для проекта.
project_info() {
  case "$1" in
    site)
      NAME="Сайт ohota-rybalka05: SEO и реклама"
      DIR="$HOME/achikol-ohothozyaistvo"
      PROMPT="Это сайт Ачикольского охотхозяйства ohota-rybalka05.ru. Снимки прошлых деплоев лежат в ~/_backups/achikol-*.
Отчёты по сайту: аудит 1 сентября $ART/Sgd279SLkcgoqPdB6MQ4op, рабочие материалы 2 сентября $ART/PQxiG8sb8vd821uxuuQjFz,
SEO и GEO $ART/9GSeweyngCiwVYTcAf7ffH, «Ачиколь в поиске» 17 сентября $ART/UNtByTAp3Y2d4h1T45cxkS,
«Ачиколь на чужих площадках» 17 сентября $ART/VFYdxSUqjvquUAqFbzd12D.
Реклама: Директ $ART/2Er5Vd448EcA5uNk6QfZtv, Авито $ART/C8RiRg7kfx7ehGeU7r2VTV, пакет объявлений $ART/LqEBr4dSd4tKxmnWxgJ5qB.
$COMMON" ;;
    bot)
      NAME="Telegram-бот Growth OS"
      DIR="$HOME/ohota-gos"
      PROMPT="Это Growth OS для Ачикольского охотхозяйства: Telegram-бот «отдел продаж» и отчёты по Директу.
Отчёты: аудит перед запуском 8 сентября $ART/1HnTybcgbycoiV6H5Hik51, RC1 9 сентября $ART/TbL6AYwWeH5hp6W1Caod5Y,
памятка управляющего $ART/3Yru56J2mn1wy3S9pituwb. Подробности о проверке — в docs/RC1.md.
$COMMON" ;;
    crm)
      NAME="CRM охотхозяйства"
      DIR="$HOME/ohota-crm"
      PROMPT="Это CRM Ачикольского охотхозяйства: веб-версия (React и API на PHP) и Android-приложение.
Отчёт: Marketing OS — аудит и архитектура, 3 сентября $ART/JhyVUBjpdV9vwiRBRreY9G.
В папке лежат ключ Firebase и keystore для подписи приложения: не открывай их и не выводи.
$COMMON" ;;
    game)
      NAME="Игра КОНСУМАЦИЯ"
      DIR="$HOME/konsumaciya"
      PROMPT="Это браузерная хоррор-игра «КОНСУМАЦИЯ» в одном файле index.html, сделана 5 сентября. Отчётов по ней нет.
Опиши, как устроена игра (карта, монстр и его поведение, ключи, звук, скример, управление), чтобы дальше её дорабатывать.
$COMMON" ;;
    *) return 1 ;;
  esac
}

# Игре нужна своя папка: раньше она лежала в ~/Downloads/magicui-main вместе с чужим шаблоном.
prepare_game() {
  local src="$HOME/Downloads/magicui-main" dst="$HOME/konsumaciya"
  mkdir -p "$dst" || return 1
  if [ ! -f "$dst/index.html" ]; then
    if grep -q "КОНСУМАЦИЯ" "$src/index.html" 2>/dev/null; then
      cp -p "$src/index.html" "$dst/index.html"
    else
      curl -fsSL "$GAME_URL" -o "$dst/index.html" || return 1
    fi
  fi
  for f in face.jpg body.jpg; do
    [ -f "$src/$f" ] && [ ! -f "$dst/$f" ] && cp -p "$src/$f" "$dst/$f"
  done
  return 0
}

new_session_id() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
    return
  fi
  perl -e 'my @r = map { int rand 65536 } 1..8;
           printf "%04x%04x-%04x-%04x-%04x-%04x%04x%04x\n",
             @r[0,1,2], ($r[3] & 0x0fff) | 0x4000, ($r[4] & 0x3fff) | 0x8000, @r[5,6,7]'
}

auth_field() {
  claude auth status 2>/dev/null | perl -ne 'print $1 if /"'"$1"'"\s*:\s*"([^"]+)"/'
}

# 0, если Claude Code ходит в API по ключу (кредиты Console), а не по подписке.
uses_api_key() {
  case "$(auth_field authMethod)" in api_key|api_key_helper) return 0 ;; esac
  [ -n "$(auth_field apiKeySource)" ]
}

# Объясняет, откуда Claude Code в Терминале берёт API-ключ. KEY_IN_FILES=1, если ключ
# задан переменной окружения или в файлах настроек: тогда его надо убрать оттуда вручную.
KEY_IN_FILES=0
explain_api_key() {
  local f lines
  echo "Claude Code в Терминале работает через API-ключ Anthropic Console и платит за запросы"
  echo "кредитами этого ключа, а не подпиской claude.ai, как приложение Claude. Когда кредиты"
  echo "кончаются, каждый запуск падает с ошибкой «Credit balance is too low»."
  echo
  echo "Источник ключа: $(auth_field apiKeySource)"
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    echo "Ключ задан переменной ANTHROPIC_API_KEY."
    KEY_IN_FILES=1
  fi
  for f in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zshenv" "$HOME/.bash_profile" \
           "$HOME/.bashrc" "$HOME/.profile" "$CLAUDE_DIR/settings.json"; do
    [ -f "$f" ] || continue
    lines=$(grep -n -E 'ANTHROPIC_API_KEY|apiKeyHelper' "$f" 2>/dev/null | cut -d: -f1 | tr '\n' ' ')
    [ -n "$lines" ] || continue
    echo "Ключ подключается в $f, строки: $lines(значение не показываю)"
    KEY_IN_FILES=1
  done
}

print_manual_steps() {
  echo
  echo "Чтобы работать по подписке, как в приложении:"
  if [ "$KEY_IN_FILES" = 1 ]; then
    echo "  1. В файлах выше поставьте # в начале этих строк и сохраните."
    echo "  2. Закройте Терминал и откройте новое окно."
    echo "  3. Выполните: claude auth login — и войдите тем же аккаунтом, что и в приложении Claude."
  else
    echo "  1. Выполните: claude auth logout"
    echo "  2. Выполните: claude auth login — и войдите тем же аккаунтом, что и в приложении Claude."
  fi
  echo "  Потом снова: bash ~/reopen.sh"
  echo
  echo "Если хотите платить кредитами API, пополните баланс на console.anthropic.com"
  echo "и запустите так: REOPEN_ALLOW_API_KEY=1 bash ~/reopen.sh"
}

# Спрашивает разрешения и переводит Claude Code в Терминале с ключа Console на подписку.
offer_switch() {
  local answer
  echo
  printf 'Переключить Claude Code в Терминале на подписку прямо сейчас? Откроется браузер. [Д/н] '
  if ! read -r answer < /dev/tty 2>/dev/null; then
    echo
    print_manual_steps
    return 1
  fi
  case "$answer" in
    ""|д|Д|да|Да|y|Y|yes) ;;
    *) print_manual_steps; return 1 ;;
  esac
  claude auth logout || { print_manual_steps; return 1; }
  echo "Вход по подписке: в браузере подтвердите вход тем же аккаунтом, что и в приложении Claude."
  if ! claude auth login; then
    echo "Вход не завершён."
    print_manual_steps
    return 1
  fi
  if uses_api_key; then
    echo "Claude Code всё ещё работает через API-ключ."
    print_manual_steps
    return 1
  fi
  echo "Готово: Claude Code в Терминале работает по подписке. Продолжаю."
  echo
}

# 0, если в сессии нет ни одного ответа Claude, кроме сообщений об ошибке API.
# Такие сессии остаются от запусков, упавших ещё до работы.
is_empty_session() {
  ! grep '"type":"assistant"' "$1" | grep -v -e '"isApiErrorMessage":true' -e '"model":"<synthetic>"' \
      | grep -q .
}

remove_session() {
  rm -f "$1"
  rm -rf "${1%.jsonl}"
}

# Убирает пустые сессии, созданные прошлыми неудачными запусками этого скрипта.
cleanup_failed_runs() {
  local idf id t removed=0
  for idf in "$HOME"/claude-reopen-*/*.id; do
    [ -f "$idf" ] || continue
    [ "$(cat "${idf%.id}.exit" 2>/dev/null)" = 0 ] && continue
    id=$(cat "$idf")
    for t in "$PROJECTS_DIR"/*/"$id.jsonl"; do
      [ -f "$t" ] && is_empty_session "$t" || continue
      remove_session "$t"
      removed=$((removed + 1))
    done
  done
  [ "$removed" -gt 0 ] && echo "Убраны пустые сессии от прошлых неудачных запусков: $removed"
  return 0
}

# 0, если установленный Claude Code не старше версии в аргументе.
claude_at_least() {
  claude --version 2>/dev/null | awk -v need="$1" '
    { split($1, h, "."); split(need, n, ".")
      for (i = 1; i <= 3; i++) { if (h[i] + 0 > n[i] + 0) exit 0; if (h[i] + 0 < n[i] + 0) exit 1 }
      exit 0 }'
}

start_session() {
  local key="$1" id
  project_info "$key"
  id=$(new_session_id)
  echo "$id" > "$LOGDIR/$key.id"
  ( cd "$DIR" && claude -p "$PROMPT" \
      --session-id "$id" --name "$NAME" \
      --permission-prompts none --max-turns 40 \
      --allowedTools "Read,Glob,Grep,Artifact,Bash(ls *),Bash(git log *),Bash(git status *)" \
  ) > "$LOGDIR/$key.txt" 2>&1
  echo $? > "$LOGDIR/$key.exit"
}

if ! command -v claude >/dev/null 2>&1; then
  echo "Команда claude не найдена. Установите Claude Code: https://code.claude.com/docs/en/setup"
  exit 1
fi
if ! claude_at_least 2.1.259; then
  echo "Claude Code слишком старый ($(claude --version 2>/dev/null | head -1)). Обновите: claude update"
  exit 1
fi
# Приложение Claude входит в аккаунт само по себе, а Claude Code в Терминале — отдельно.
if ! claude auth status >/dev/null 2>&1; then
  echo "Claude Code в Терминале не вошёл в аккаунт. Выполните: claude auth login"
  echo "Войдите тем же аккаунтом, что и в приложении Claude, и запустите скрипт снова."
  exit 1
fi
if uses_api_key && [ -z "${REOPEN_ALLOW_API_KEY:-}" ]; then
  explain_api_key
  if [ "$KEY_IN_FILES" = 1 ]; then
    print_manual_steps
    exit 1
  fi
  offer_switch || exit 1
fi
cleanup_failed_runs
for key in $SELECTED; do
  project_info "$key" || { echo "Неизвестный проект: $key (есть: $ALL)"; exit 2; }
done
mkdir -p "$LOGDIR" || exit 1
echo "Журналы: $LOGDIR"

STARTED=""
for key in $SELECTED; do
  project_info "$key"
  if [ "$key" = game ] && ! prepare_game; then
    echo "  пропущено  $NAME — не удалось подготовить папку $DIR"
    continue
  fi
  if [ ! -d "$DIR" ]; then
    echo "  пропущено  $NAME — нет папки $DIR"
    continue
  fi
  echo "  запущено   $NAME  ($DIR)"
  start_session "$key" &
  STARTED="$STARTED $key"
done
[ -n "$STARTED" ] || { echo "Нечего открывать."; exit 1; }

echo
echo "Claude читает отчёты и код во всех проектах сразу. Обычно это занимает 3–10 минут."
wait

echo
if claude_at_least 2.1.285; then CAN_OPEN=1; else CAN_OPEN=0; fi
CREATED=0
OPENED=0
for key in $STARTED; do
  project_info "$key"
  id=$(cat "$LOGDIR/$key.id")
  code=$(cat "$LOGDIR/$key.exit" 2>/dev/null || echo "?")
  if [ "$code" = 0 ]; then
    echo "  готово     $NAME"
  else
    echo "  с ошибкой  $NAME (код $code). Конец журнала $LOGDIR/$key.txt:"
    tail -5 "$LOGDIR/$key.txt" | sed 's/^/               /'
  fi
  # Сессия могла сохраниться и после ошибки: с полезной работой, если кончился лимит ходов,
  # или пустой, если запрос не прошёл. Пустую убираем, чтобы не засоряла список сессий.
  transcript=""
  for t in "$PROJECTS_DIR"/*/"$id.jsonl"; do [ -f "$t" ] && transcript="$t"; done
  if [ -n "$transcript" ] && is_empty_session "$transcript"; then
    remove_session "$transcript"
    transcript=""
  fi
  if [ -z "$transcript" ]; then
    echo "             сессия не создана"
    continue
  fi
  CREATED=$((CREATED + 1))
  if [ "$CAN_OPEN" = 1 ]; then
    # --desktop отказывается работать с перенаправленным выводом, поэтому пишет прямо в Терминал.
    if ( cd "$DIR" && claude --desktop --resume "$id" ); then
      OPENED=$((OPENED + 1))
    else
      echo "             не открылась в приложении (причина выше)."
      echo "             Вручную: cd \"$DIR\" && claude --desktop --resume $id"
    fi
    sleep 2
  fi
done

echo
if [ "$CREATED" = 0 ]; then
  echo "Ни одна сессия не создана. Пришлите ошибку, которую Claude Code вывел выше."
  exit 1
fi
if [ "$OPENED" -gt 0 ]; then
  echo "Открыто в приложении Claude: $OPENED из $CREATED, каждая сессия в папке своего проекта."
elif [ "$CAN_OPEN" = 1 ]; then
  echo "Сессий создано: $CREATED, но в приложении Claude они не открылись — причина выше."
else
  echo "Claude Code старше 2.1.285 и не умеет сам открывать сессии в приложении."
  echo "Обновите его (claude update) и запустите скрипт снова, или в приложении Claude"
  echo "наберите /resume в поле ввода и выберите сессию по названию."
fi
echo "Сводки Claude лежат и в журналах: $LOGDIR/<проект>.txt"
echo "Старые строки «Session not found on disk» в боковой панели убираются кнопкой Archive."
