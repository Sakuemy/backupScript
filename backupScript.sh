#!/bin/bash

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# Настройки
SNAPSHOT_NAME="backup$(date +%Y%m%d)"
NAME_PV="ubuntu--vg"
NAME_VG="ubuntu--vg-ubuntu--lv"
SIZE_SNAPSHOT="5G"
MOUNT_POINT="/mnt/smb"
SMB_SHARE="//XXXXXXXXX/XXXXXXXXX/"
SMB_USER="XXXXXXXX"
SMB_PASSWORD="XXXXXXXXXXXXXXXXXXXX"
BACKUP_DIR="$MOUNT_POINT/XXXXXXXXXXXXXX"
COPY_STORAGE_TIME=30
TELEGRAM_BOT_TOKEN="XXXXXXXXXXXXXXXX:XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXx"
TELEGRAM_CHAT_ID="XXXXXXXXXXXXXX"
SERVER_NAME="Name"

# Функция для отправки уведомлений в Telegram
send_telegram_message() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d text="$SERVER_NAME. $message"
}

# Создание снапшота
create_snapshot() {
    echo "Создаем снапшот $SNAPSHOT_NAME..."
    if ! lvcreate --snapshot --name "$SNAPSHOT_NAME" --size $SIZE_SNAPSHOT "/dev/mapper/$NAME_VG"; then
        send_telegram_message "Ошибка: не удалось создать снапшот $SNAPSHOT_NAME"
        exit 1
    fi
        mkdir -p /mnt/snapshot
    if ! mount /dev/mapper/"$NAME_PV-$SNAPSHOT_NAME" /mnt/snapshot; then send_telegram_message "Ошибка: не удалось примонтировать снапшот $SNAPSHOT_NAME" delete_snapshot exit 1
    fi
}

# Подключение папки SMB
mount_smb() {
    echo "Подключаем SMB папку..."
    mkdir -p "$MOUNT_POINT"
    if ! mount -t cifs "$SMB_SHARE" "$MOUNT_POINT" -o username="$SMB_USER",password="$SMB_PASSWORD"; then
        send_telegram_message "Ошибка: не удалось подключить SMB папку $SMB_SHARE"
        delete_snapshot
        exit 1
    fi
}

# Отключение SMB
unmount_smb() {
    echo "Отключаем SMB папку..."
    if ! umount "$MOUNT_POINT"; then
        send_telegram_message "Предупреждение: не удалось отключить SMB папку $MOUNT_POINT"
    fi
}

# Резервное копирование
create_backup() {
    # Пути, которые нужно исключить
    EXCLUDES=(
        --exclude=/mnt/snapshot/proc
        --exclude=/mnt/snapshot/sys
        --exclude=/mnt/snapshot/dev
        --exclude=/mnt/snapshot/run
        --exclude=/mnt/snapshot/tmp
        --exclude=/mnt/snapshot/mnt
        --exclude=/mnt/snapshot/media
        --exclude=/mnt/snapshot/swap.img
    )
    TIME_BACKUP=$(date +%Y-%m-%d-%H%M)
    IFS=',' read -r last_full_backup_marker rest <<< $(tac "$BACKUP_DIR/list_all_backubs.csv" | grep -m 1 "full_backup_marker-")
    if [[ !($(date +%d) -eq 1) && -f "$BACKUP_DIR/$last_full_backup_marker" ]]; then
        echo "Создаем инкрементную резервную копию..."
        echo inc-$TIME_BACKUP.tar.gz,$TIME_BACKUP>>"$BACKUP_DIR/list_all_backubs.csv"
        if ! tar "${EXCLUDES[@]}" --listed-incremental="$BACKUP_DIR/$last_full_backup_marker" -czf "$BACKUP_DIR/inc-$TIME_BACKUP.tar.gz" /mnt/snapshot; then
            send_telegram_message "Ошибка: не удалось создать инкрементную резервную копию"
            delete_snapshot
            unmount_smb
            exit 1
        fi
    else
        echo "Создаем полную резервную копию..."
        echo full-$TIME_BACKUP.tar.gz,$TIME_BACKUP>>"$BACKUP_DIR/list_all_backubs.csv"
        echo full_backup_marker-$TIME_BACKUP,$TIME_BACKUP>>"$BACKUP_DIR/list_all_backubs.csv"
        touch "$BACKUP_DIR/full_backup_marker-$TIME_BACKUP"
        if ! tar "${EXCLUDES[@]}" --listed-incremental="$BACKUP_DIR/full_backup_marker-$TIME_BACKUP" -czf "$BACKUP_DIR/full-$TIME_BACKUP.tar.gz" /mnt/snapshot; then
            send_telegram_message "Ошибка: не удалось создать полную резервную копию"
            delete_snapshot
            unmount_smb
            exit 1
        fi
    fi
}

# Удаление снапшота
delete_snapshot() {
    echo "Удаляем снапшот $SNAPSHOT_NAME..."
    sleep 5
    umount /mnt/snapshot
    if ! lvremove -f /dev/mapper/"$NAME_PV-$SNAPSHOT_NAME"; then
        send_telegram_message "Ошибка: не удалось удалить снапшот $SNAPSHOT_NAME"
    fi
}

# Логика очистки бэкапов
delete_old_backup() {
    # Объявление массивов
    names=()
    dates=()
    days_ago=$(date -d "$COPY_STORAGE_TIME days ago" '+%s')
    count=0
    count_2=0
    bool=0
    while IFS=',' read -r name date; do
        ((count_2++))
        formatted_date=$(echo "$date" | tr -d '\r' | sed -E 's/^([0-9]{4}-[0-9]{2}-[0-9]{2})-([0-9]{2})([0-9]{2})$/\1 \2:\3/' | xargs -I{} date -d "{}" +"%Y-%m-%d %H:%M")
        backup_date_ts=$(date -d "$formatted_date" '+%s')
        if (( backup_date_ts < days_ago )); then
             echo "Есть старые бэкапы"
             if [[ $name == full-* && $count -gt 0 ]]; then
                 deletefiles
                 names=()
                 count=0
                 bool=1
             fi
             ((count++))
        else
            if [[ $name == full-* && $count -gt 0 ]]; then
                deletefiles
                bool=1
            fi
            echo "Нечего удалять"
            break
        fi
        names+=("$name")
        ((count++))
    done < "$BACKUP_DIR/list_all_backubs.csv"
    if [[ $count_2 -gt 0 && $bool -eq 1 ]]; then
        count_2_minus_1=$((count_2 - 1))
        sed -i "1,${count_2_minus_1}d" "$BACKUP_DIR/list_all_backubs.csv"
        bool=0
    fi
}

# Удаление файлов
deletefiles() {
    # Удаление файлов
    for file in "${names[@]}"; do
        if [[ -f "$BACKUP_DIR/$file" ]]; then
            rm -f "$BACKUP_DIR/$file"
            echo "Удален файл $file"
        fi
    done

}

# Основной процесс
main() {
    if [[ -f "$BACKUP_DIR/list_all_backubs.csv" ]]; then
         touch "$BACKUP_DIR/list_all_backubs.csv"
    fi
    create_snapshot
    mount_smb
    create_backup
    delete_old_backup
    unmount_smb
    delete_snapshot
}

# Выполнение
main
