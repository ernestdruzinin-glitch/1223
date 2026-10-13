#!/bin/bash
# Спасает сессии и находит проекты Claude Code на Маке.
#
#   1. Копирует историю сессий (~/.claude/projects) в ~/claude-sessions-backup-<дата>.
#   2. Ставит cleanupPeriodDays = 3650 в ~/.claude/settings.json, чтобы Claude Code
#      перестал удалять сессии старше 30 дней. Старый файл кладёт в ту же копию.
#   3. Ищет удалённые сессии в Time Machine и возвращает недостающие. Ничего не перезаписывает.
#   4. Показывает, какие сессии остались и где лежат папки проектов.
#      Отчёт сохраняется в REPORT.txt внутри папки с копией.
#
# Запуск:   bash rescue-claude-sessions.sh
#           bash rescue-claude-sessions.sh --no-settings   # не менять settings.json
#           bash rescue-claude-sessions.sh --no-restore    # не трогать Time Machine

set -u

KEEP_DAYS=3650
CHANGE_SETTINGS=1
RESTORE=1
for arg in "$@"; do
  case "$arg" in
    --no-settings) CHANGE_SETTINGS=0 ;;
    --no-restore)  RESTORE=0 ;;
    -h|--help)     sed -n '2,15p' "$0"; exit 0 ;;
    *)             echo "Неизвестный параметр: $arg" >&2; exit 2 ;;
  esac
done

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PROJECTS="$CLAUDE_DIR/projects"
SETTINGS="$CLAUDE_DIR/settings.json"
BACKUP="$HOME/claude-sessions-backup-$(date +%Y%m%d-%H%M%S)"

# Папки, которые упоминаются в отчётах прошлых сессий (см. PROJECTS.md).
KNOWN_PLACES="
$HOME/Downloads/magicui-main
$HOME/ohota-gos
$HOME/ohota-crm
$HOME/Desktop/Ачикольское_Отобранный_Контент
"

section() { printf '\n=== %s ===\n' "$1"; }

backup_sessions() {
  section "1. Резервная копия истории сессий"
  if [ ! -d "$PROJECTS" ]; then
    echo "Папки $PROJECTS нет — копировать нечего."
    return
  fi
  if cp -Rp "$PROJECTS" "$BACKUP/projects"; then
    echo "Скопировано в $BACKUP/projects ($(du -sh "$BACKUP/projects" | cut -f1))"
  else
    echo "ОШИБКА: копия сделана не полностью, смотрите сообщения выше."
  fi
  [ -f "$SETTINGS" ] && cp -p "$SETTINGS" "$BACKUP/settings.json.bak"
}

# Возвращает 0, если после работы функции сессии больше не удаляются через 30 дней.
set_retention() {
  section "2. Отключение автоудаления сессий"
  if [ "$CHANGE_SETTINGS" = 0 ]; then
    echo "Пропущено (--no-settings)."
    return 1
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
    return 0
  fi
  echo "НЕ получилось. Добавьте в $SETTINGS вручную строку: \"cleanupPeriodDays\": $KEEP_DAYS"
  return 1
}

restore_from_time_machine() {
  section "3. Поиск удалённых сессий в Time Machine"
  if [ "$RESTORE" = 0 ]; then
    echo "Пропущено (--no-restore)."
    return
  fi
  if [ "$1" != 0 ]; then
    echo "Пропущено: автоудаление не отключено, восстановленные сессии снова удалились бы."
    return
  fi
  if ! command -v tmutil >/dev/null 2>&1; then
    echo "Time Machine на этом компьютере нет."
    return
  fi
  local backups
  backups=$(tmutil listbackups 2>/dev/null | sort -r)
  if [ -z "$backups" ]; then
    echo "Копий Time Machine не видно: диск не подключён, копий нет,"
    echo "или Терминалу нужен «Полный доступ к диску» (Настройки → Конфиденциальность)."
    return
  fi
  local rel="${PROJECTS#/}" restored="$BACKUP/restored.txt"
  : > "$restored"
  echo "$backups" | while IFS= read -r b; do
    for src in "$b"/*/"$rel" "$b/$rel"; do
      [ -d "$src" ] || continue
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
  done
  echo "Восстановлено сессий: $(wc -l < "$restored" | tr -d ' ')."
}

list_sessions() {
  section "4. Сессии, которые есть на диске (новые сверху)"
  [ -d "$PROJECTS" ] || { echo "Нет папки $PROJECTS."; return; }
  perl -Mutf8 -MJSON::PP -MPOSIX=strftime -MEncode=decode -e '
    my ($root) = @ARGV;
    my $json = JSON::PP->new->utf8;
    binmode STDOUT, ":utf8";
    binmode STDERR, ":utf8";
    my @files;
    opendir my $top, $root or die "не открыть ", decode("UTF-8", $root), ": $!\n";
    for my $dir (grep { !/^\./ && -d "$root/$_" } readdir $top) {
      opendir my $d, "$root/$dir" or next;
      push @files, map { "$root/$dir/$_" } grep { /\.jsonl$/ } readdir $d;
      closedir $d;
    }
    closedir $top;
    my @rows;
    for my $f (@files) {
      open my $in, "<", $f or next;
      my ($cwd, $title, $first);
      while (my $line = <$in>) {
        if (!defined $cwd && $line =~ /"cwd":("(?:[^"\\]|\\.)*")/) {
          $cwd = eval { $json->decode("[$1]")->[0] };
        }
        if ($line =~ /"type":"(?:custom-title|ai-title|summary)"/) {
          my $o = eval { $json->decode($line) } or next;
          my $t = $o->{customTitle} // $o->{aiTitle} // $o->{title} // $o->{summary};
          $title = $t if defined $t && !($title && $o->{type} eq "summary");
          next;
        }
        if (!defined $first && $line =~ /"type":"user"/) {
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
      printf "%s  %s\n    папка: %s\n    файл:  %s\n",
        strftime("%Y-%m-%d %H:%M", localtime $r->[0]), $r->[2], $r->[1], $r->[3];
    }
    printf "Всего сессий: %d\n", scalar @rows;
  ' "$PROJECTS"
}

find_projects() {
  section "5. Папки проектов"
  echo "Известные по прошлым отчётам:"
  echo "$KNOWN_PLACES" | while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -e "$p" ]; then echo "  есть  $p"; else echo "  НЕТ   $p"; fi
  done
  echo
  echo "Похожие по названию (поиск в домашней папке, глубина 4):"
  find "$HOME" -maxdepth 4 \
    \( -path "$HOME/Library" -o -path "$HOME/.Trash" -o -path "$CLAUDE_DIR" \
       -o -path "$BACKUP" -o -name node_modules -o -name .git \) -prune \
    -o \( -iname '*ohota*' -o -iname '*achikol*' -o -iname '*ачикол*' \
          -o -iname 'magicui*' -o -iname '*konsum*' -o -iname '*консумац*' \) -print \
    2>/dev/null | sed 's/^/  /'
}

main() {
  echo "Копия и отчёт: $BACKUP"
  backup_sessions
  set_retention
  local retention_ok=$?
  restore_from_time_machine "$retention_ok"
  list_sessions
  find_projects
  section "Готово"
  echo "Отчёт: $BACKUP/REPORT.txt"
  echo "Перезапустите приложение Claude, чтобы оно перечитало список сессий."
}

mkdir -p "$BACKUP" || exit 1
main 2>&1 | tee "$BACKUP/REPORT.txt"
