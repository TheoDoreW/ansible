#!/bin/zsh

# 设置变量
DESTINATION_STORAGE_ACCOUNT="hctssa1"
CONTAINER_NAME="logfile"
SAS_TOKEN="sv=2022-11-02&ss=bfqt&srt=sco&sp=rwdlacupiytfx&se=2024-12-09T20:53:21Z&st=2024-12-09T12:53:21Z&spr=https&sig=STlfQ4yK1gf8L5m5A8z2rdVCCtBYPZgSwiEkBOiaxsU%3D"
LOCAL_DIR="/Users/xinsheng.wang/xinsheng/azcopy"

# 下载所有日志文件
azcopy list "https://$DESTINATION_STORAGE_ACCOUNT.blob.core.windows.net/$CONTAINER_NAME?$SAS_TOKEN" --output-type=text > $LOCAL_DIR/file-list.txt

# 过滤并下载日志文件
while IFS= read -r line; do
  if echo "$line" | grep -q "azcopy-log-"; then
    file=$(echo "$line" | awk '{print $1}')
    azcopy copy "https://$DESTINATION_STORAGE_ACCOUNT.blob.core.windows.net/$CONTAINER_NAME/$file?$SAS_TOKEN" "$LOCAL_DIR/"
  fi
done < $LOCAL_DIR/file-list.txt

# 合并日志文件
cat $LOCAL_DIR/azcopy-log-*.txt > $LOCAL_DIR/azcopy-merged-log.txt

# 上传合并后的日志文件
azcopy copy "$LOCAL_DIR/azcopy-merged-log.txt" "https://$DESTINATION_STORAGE_ACCOUNT.blob.core.windows.net/$CONTAINER_NAME/azcopy-merged-log.txt?$SAS_TOKEN"