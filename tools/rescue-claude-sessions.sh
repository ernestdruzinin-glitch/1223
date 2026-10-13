#!/bin/bash
# Спасает сессии и находит проекты Claude Code на Маке.
#
#   1. Копирует историю сессий (~/.claude/projects) в ~/claude-sessions-backup-<дата>.
#   2. Ставит cleanupPeriodDays = 3650 в ~/.claude/settings.json, чтобы Claude Code
#      перестал удалять сессии старше 30 дней. Старый файл кладёт в ту же копию.
#   3. Ищет удалённые сессии в Time Machine и возвращает недостающие. Ничего не перезаписывает.
#      Ищет копии переписки в Корзине, ~/_backups и папке приложения Claude.
#   4. Показывает, какие сессии остались и где лежат папки проектов.
#      Отчёт сохраняется в REPORT.txt внутри папки с копией.
#
# Запуск:   bash rescue-claude-sessions.sh
#           bash rescue-claude-sessions.sh --no-backup     # не копировать историю ещё раз
#           bash rescue-claude-sessions.sh --no-settings   # не менять settings.json
#           bash rescue-claude-sessions.sh --no-restore    # не трогать Time Machine

set -u

KEEP_DAYS=3650
MAKE_BACKUP=1
CHANGE_SETTINGS=1
RESTORE=1
for arg in "$@"; do
  case "$arg" in
    --no-backup)   MAKE_BACKUP=0 ;;
    --no-settings) CHANGE_SETTINGS=0 ;;
    --no-restore)  RESTORE=0 ;;
    -h|--help)     sed -n '2,17p' "$0"; exit 0 ;;
    *)             echo "Неизвестный параметр: $arg" >&2; exit 2 ;;
  esac
done

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PROJECTS="$CLAUDE_DIR/projects"
SETTINGS="$CLAUDE_DIR/settings.json"
BACKUP="$HOME/claude-sessions-backup-$(date +%Y%m%d-%H%M%S)"

# Папки проектов, найденные прошлыми запусками и отчётами (см. PROJECTS.md).
KNOWN_PLACES="
$HOME/achikol-ohothozyaistvo
$HOME/ohota-gos
$HOME/ohota-crm
$HOME/achikol-content-bot
$HOME/Downloads/magicui-main
$HOME/Desktop/сайт
$HOME/Desktop/Ачикольское_Отобранный_Контент
"

# Где ещё могли остаться копии переписки.
OTHER_COPIES="
$HOME/.Trash
$HOME/_backups
$HOME/Library/Application Support/Claude
"

section() { printf '\n=== %s ===\n' "$1"; }

backup_sessions() {
  section "1. Резервная копия истории сессий"
  [ -f "$SETTINGS" ] && cp -p "$SETTINGS" "$BACKUP/settings.json.bak"
  if [ "$MAKE_BACKUP" = 0 ]; then
    echo "Пропущено (--no-backup)."
    return
  fi
  if [ ! -d "$PROJECTS" ]; then
    echo "Папки $PROJECTS нет — копировать нечего."
    return
  fi
  if cp -Rp "$PROJECTS" "$BACKUP/projects"; then
    echo "Скопировано в $BACKUP/projects ($(du -sh "$BACKUP/projects" | cut -f1))"
  else
    echo "ОШИБКА: копия сделана не полностью, смотрите сообщения выше."
  fi
}

set_retention() {
  section "2. Отключение автоудаления сессий"
  if [ "$CHANGE_SETTINGS" = 0 ]; then
    echo "Пропущено (--no-settings)."
    return
  fi
  mkdir -p "$CLAUDE_DIR"
  if perl -MJSON::PP -e '
      my ($file, $days) = @ARGV;
      my $json = JSON::PP->new->utf8->pretty->canonical;
      my $data = {};
      if (-s $file) {
        open my $in, "<", $file or die "не открыть $file: $!\n";
        my $text = do { local $/; <$in> };
        close $in;
        $data = eval { $json->decode($text) };
        die "$file — не JSON, правьте вручную: $@" unless ref $data eq "HASH";
      }
      $data->{cleanupPeriodDays} = $days + 0;
      open my $out, ">", "$file.tmp" or die "не записать $file.tmp: $!\n";
      print $out $json->encode($data);
      close $out or die "не записать $file.tmp: $!\n";
      rename "$file.tmp", $file or die "не заменить $file: $!\n";
    ' "$SETTINGS" "$KEEP_DAYS"; then
    echo "В $SETTINGS записано \"cleanupPeriodDays\": $KEEP_DAYS."
    echo "Прежний файл: $BACKUP/settings.json.bak (если он был)."
  else
    echo "НЕ получилось. Добавьте в $SETTINGS вручную строку: \"cleanupPeriodDays\": $KEEP_DAYS"
  fi
}

# Успех, если в settings.json сейчас стоит срок хранения больше стандартных 30 дней.
retention_is_off() {
  [ -f "$SETTINGS" ] && perl -MJSON::PP -e '
    open my $in, "<", $ARGV[0] or exit 1;
    my $data = eval { JSON::PP->new->utf8->decode(do { local $/; <$in> }) } or exit 1;
    exit((($data->{cleanupPeriodDays} // 0) > 30) ? 0 : 1);
  ' "$SETTINGS"
}

restore_from_time_machine() {
  section "3. Поиск удалённых сессий в Time Machine"
  if [ "$RESTORE" = 0 ]; then
    echo "Пропущено (--no-restore)."
    return
  fi
  if ! retention_is_off; then
    echo "Пропущено: автоудаление не отключено, восстановленные сессии снова удалились бы."
    return
  fi
  if ! command -v tmutil >/dev/null 2>&1; then
    echo "Time Machine на этом компьютере нет."
    return
  fi
  local list="$BACKUP/tmutil-listbackups.txt" restored="$BACKUP/restored.txt"
  local rel="${PROJECTS#/}" total=0 readable=0 with_sessions=0
  tmutil listbackups > "$list" 2>&1
  : > "$restored"
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    total=$((total + 1))
    [ -d "$b" ] || continue
    readable=$((readable + 1))
    for src in "$b"/*/"$rel" "$b/$rel"; do
      [ -d "$src" ] || continue
      with_sessions=$((with_sessions + 1))
      ( cd "$src" && find . -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' ) | while IFS= read -r f; do
        f="${f#./}"
        [ -e "$PROJECTS/$f" ] && continue
        mkdir -p "$PROJECTS/${f%/*}"
        cp -p "$src/$f" "$PROJECTS/$f" || continue
        # Рядом с сессией лежит папка с субагентами и большими выводами инструментов.
        d="${f%.jsonl}"
        [ -d "$src/$d" ] && [ ! -e "$PROJECTS/$d" ] && cp -Rp "$src/$d" "$PROJECTS/$d"
        echo "$f" >> "$restored"
        echo "Восстановлено: $f"
      done
    done
  done < <(sort -r "$list")

  if [ "$readable" = 0 ]; then
    if [ -s "$list" ]; then
      echo "Копии Time Machine прочитать не удалось. Ответ tmutil:"
      sed 's/^/  /' "$list" | head -5
    else
      echo "tmutil не вернул ни одной копии Time Machine."
    fi
    if grep -q "No machine directory found" "$list"; then
      echo "Time Machine не нашла ни одной резервной копии этого Мака: скорее всего, она"
      echo "не настроена. Проверьте: Системные настройки → Основные → Time Machine."
      echo "Если диска для копий там нет, удалённые сессии восстановить нельзя."
      return
    fi
    echo "Обычно это значит одно из трёх: Time Machine не настроена, диск с копиями"
    echo "не подключён, или у Терминала нет «Полного доступа к диску»"
    echo "(Системные настройки → Конфиденциальность и безопасность → Полный доступ к диску)."
    echo "Исправьте и запустите ещё раз: bash rescue-claude-sessions.sh --no-backup"
    return
  fi
  echo "Копий Time Machine: $total, прочитано: $readable, с папкой сессий: $with_sessions."
  if [ "$with_sessions" = 0 ]; then
    echo "Ни в одной копии нет $PROJECTS — эту папку Time Machine не сохраняла."
  fi
  echo "Восстановлено сессий: $(wc -l < "$restored" | tr -d ' ')."
}

find_other_copies() {
  section "3б. Копии переписки вне ~/.claude"
  local copies="$BACKUP/other-copies.txt" cowork="$BACKUP/cowork-sessions.txt"
  local other="$BACKUP/other-session-files.txt"
  : > "$copies"
  while IFS= read -r p; do
    [ -n "$p" ] && [ -d "$p" ] || continue
    find "$p" -type f -name '*.jsonl' -size +1k ! -path '*/subagents/*' 2>/dev/null |
      while IFS= read -r f; do
        grep -q -m1 '"sessionId"' "$f" 2>/dev/null && echo "$f" >> "$copies"
      done
  done <<< "$OTHER_COPIES"
  grep '/local-agent-mode-sessions/' "$copies" > "$cowork"
  grep -v '/local-agent-mode-sessions/' "$copies" > "$other"
  if [ ! -s "$copies" ]; then
    echo "Не найдено (смотрели Корзину, ~/_backups и папку приложения Claude)."
    return
  fi
  if [ -s "$cowork" ]; then
    echo "Сессии вкладки Cowork в приложении Claude. Они на месте, переносить их не нужно:"
    describe_sessions short < "$cowork"
  fi
  if [ -s "$other" ]; then
    [ -s "$cowork" ] && echo
    echo "Другие записи сессий Claude Code:"
    describe_sessions full < "$other"
    echo "Чтобы вернуть такую сессию, положите файл в $PROJECTS/<папка проекта>/"
    echo "и перезапустите приложение."
  fi
}

list_sessions() {
  section "4. Сессии, которые есть на диске (новые сверху)"
  [ -d "$PROJECTS" ] || { echo "Нет папки $PROJECTS."; return; }
  find "$PROJECTS" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' | describe_sessions full
}

# Печатает дату и название каждой сессии, новые сверху; в режиме full ещё папку и файл.
# Пути к файлам сессий приходят на вход, по одному в строке.
describe_sessions() {
  perl -Mutf8 -MJSON::PP -MPOSIX=strftime -MEncode=decode -e '
    my $full = $ARGV[0] eq "full";
    my $json = JSON::PP->new->utf8;
    binmode STDOUT, ":utf8";
    my @rows;
    while (my $f = <STDIN>) {
      chomp $f;
      open my $in, "<", $f or next;
      my ($cwd, $title, $first);
      while (my $line = <$in>) {
        if (!defined $cwd && $line =~ /"cwd":\s*("(?:[^"\\]|\\.)*")/) {
          $cwd = eval { $json->decode("[$1]")->[0] };
        }
        if ($line =~ /"type":\s*"(?:custom-title|ai-title|summary)"/) {
          my $o = eval { $json->decode($line) } or next;
          my $t = $o->{customTitle} // $o->{aiTitle} // $o->{title} // $o->{summary};
          $title = $t if defined $t && !($title && $o->{type} eq "summary");
          next;
        }
        if (!defined $first && $line =~ /"type":\s*"user"/) {
          my $o = eval { $json->decode($line) } or next;
          next if $o->{isMeta};
          my $c = $o->{message}{content};
          my $t = ref $c eq "ARRAY"
            ? join(" ", map { ($_->{type} // "") eq "text" ? $_->{text} : () } @$c)
            : $c;
          $first = $t if defined $t && $t =~ /\S/ && $t !~ /^\s*</;
        }
      }
      close $in;
      my $name = $title // $first // "(без текста)";
      $name =~ s/\s+/ /g;
      push @rows, [(stat $f)[9], $cwd // "?", substr($name, 0, 90), decode("UTF-8", $f)];
    }
    for my $r (sort { $b->[0] <=> $a->[0] } @rows) {
      printf "%s  %s\n", strftime("%Y-%m-%d %H:%M", localtime $r->[0]), $r->[2];
      printf "    папка: %s\n    файл:  %s\n", $r->[1], $r->[3] if $full;
    }
    printf "Всего сессий: %d\n", scalar @rows;
  ' "$1"
}

find_projects() {
  section "5. Папки проектов"
  echo "Известные:"
  echo "$KNOWN_PLACES" | while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -e "$p" ]; then echo "  есть  $p"; else echo "  НЕТ   $p"; fi
  done
  echo
  echo "Похожие по названию (домашняя папка, глубина 4; внутрь найденных папок не заходим):"
  find "$HOME" -maxdepth 4 \
    \( -path "$HOME/Library" -o -path "$HOME/.Trash" -o -path "$HOME/.ssh" \
       -o -path "$CLAUDE_DIR" -o -path "$HOME/claude-sessions-backup-*" \
       -o -name node_modules -o -name .git \) -prune \
    -o \( -iname '*ohota*' -o -iname '*achikol*' -o -iname '*ачикол*' \
          -o -iname 'magicui*' -o -iname '*konsum*' -o -iname '*консумац*' \) \
       \( -type d -prune -o -true \) -print \
    2>/dev/null | sed 's/^/  /'
}

main() {
  echo "Копия и отчёт: $BACKUP"
  backup_sessions
  set_retention
  restore_from_time_machine
  find_other_copies
  list_sessions
  find_projects
  section "Готово"
  echo "Отчёт: $BACKUP/REPORT.txt"
  echo "Перезапустите приложение Claude, чтобы оно перечитало список сессий."
}

mkdir -p "$BACKUP" || exit 1
main 2>&1 | tee "$BACKUP/REPORT.txt"
