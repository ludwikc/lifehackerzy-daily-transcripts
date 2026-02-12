#!/bin/zsh
set -euo pipefail

# -----------------------------
# Configuration
# -----------------------------
RCLONE_REMOTE="GoogleDrive:Craig"
LOCAL_DIR="${HOME}/craig-on-mikrus"
MP3_DIR="${LOCAL_DIR}/mp3"
TRANSCRIPTS_DIR="${LOCAL_DIR}/transcripts"

OPENAI_API_KEY="${OPENAI_API_KEY:-}"
DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN:-}"
DISCORD_FORUM_CHANNEL_ID="${DISCORD_FORUM_CHANNEL_ID:-}"
NEXT_DAILY_CHANNEL_ID="1120658406160732160"
MAX_DISCORD_CHARS=1800

CHATGPT_MODEL="gpt-4o-mini"
CHATGPT_PROMPT='Wygeneruj szczegółowe podsumowanie spotkania na podstawie dostarczonego transkryptu JSON. Kluczowe wymagania: 1. Format wyjściowy powinien zawierać: - Tytuł "Podsumowanie 12:34 Daily Coaching" z datą spotkania - Główne sekcje tematyczne z timestampami [MM:SS-MM:SS] - Szczegółowe punktory w każdej sekcji - Wnioski końcowe 2. Dla każdej sekcji tematycznej uwzględnij: - Kto rozpoczął temat i jaki był kontekst - Konkretne przykłady i przypadki podane przez uczestników - Praktyczne wnioski i rekomendacje - Kluczowe cytaty uczestników (w cudzysłowie) - Powiązania z innymi tematami, jeśli występują 3. Styl pisania: - Rzeczowy i konkretny - Zorientowany na wartość dla czytelnika - Unikający ogólników typu "omówiliśmy", "przedyskutowaliśmy" - Zawierający praktyczne wskazówki i wnioski 4. Szczególny nacisk na: - Praktyczne rozwiązania problemów - Realne doświadczenia uczestników - Wnioski możliwe do zastosowania przez czytelnika - Powiązania między różnymi aspektami omawianych tematów 5. Każdy punkt w sekcji powinien odpowiadać na pytania: - Jaki był konkretny problem/temat? - Jakie rozwiązania zaproponowano? - Jakie wnioski można wyciągnąć? - Jak czytelnik może wykorzystać tę wiedzę? Pamiętaj o: - Używaniu imion uczestników przy cytowaniu lub opisywaniu ich doświadczeń - Zachowaniu chronologii czasowej (timestampy) - Wyciąganiu praktycznych wniosków z każdej dyskusji - Tworzeniu powiązań między omawianymi tematami - Formułowaniu konkretnych rekomendacji dla czytelnika Podsumowanie ma być wartościowe dla osoby, która nie uczestniczyła w spotkaniu, ale chce wyciągnąć z niego praktyczne wnioski i zastosować je w swoim życiu. Finalny rezultat dostarcz w formie źródła markdown, ze stopką w postaci --- Następny Daily Coaching odbędzie się jak zwykle jutro o 12:34'
CHATGPT_FORMAT_REQUIREMENTS='Wymóg techniczny: zwróć dokładnie jedną wiadomość Markdown gotową do publikacji na Discordzie i zmieść cały tekst w maksymalnie 1800 znakach.'

LOG_FILE="${LOCAL_DIR}/transcript_script.log"

# -----------------------------
# Logging and guards
# -----------------------------
log() {
  print -- "$(date '+%Y-%m-%d %H:%M:%S') - $*"
}

on_error() {
  local exit_code="$1"
  local line_no="$2"
  log "ERROR: command failed at line ${line_no}, exit code ${exit_code}"
}

trap 'on_error "$?" "$LINENO"' ERR

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log "ERROR: missing required command: ${cmd}"
    exit 1
  fi
}

mkdir -p "${LOCAL_DIR}" "${MP3_DIR}" "${TRANSCRIPTS_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

log "Script started."

require_cmd rclone
require_cmd ffmpeg
require_cmd jq
require_cmd curl

if [[ -z "${OPENAI_API_KEY}" ]]; then
  log "ERROR: OPENAI_API_KEY is not set."
  exit 1
fi
if [[ -z "${DISCORD_BOT_TOKEN}" || -z "${DISCORD_FORUM_CHANNEL_ID}" ]]; then
  log "ERROR: DISCORD_BOT_TOKEN or DISCORD_FORUM_CHANNEL_ID is not set."
  exit 1
fi

# -----------------------------
# 1) Find and download only the newest AAC from Google Drive (no subfolders)
# -----------------------------
log "Finding newest AAC file on ${RCLONE_REMOTE} (no subfolders)."
LATEST_REMOTE_AAC="$(
  rclone lsjson "${RCLONE_REMOTE}" --files-only --max-depth 1 --include "*.aac" \
    | jq -r 'if length == 0 then empty else max_by(.ModTime).Path end'
)"

if [[ -z "${LATEST_REMOTE_AAC}" || "${LATEST_REMOTE_AAC}" == "null" ]]; then
  log "ERROR: no AAC files found on ${RCLONE_REMOTE}."
  exit 1
fi

log "Newest remote AAC: ${LATEST_REMOTE_AAC}"
DOWNLOADED_AAC="${LOCAL_DIR}/${LATEST_REMOTE_AAC:t}"
log "Downloading only newest file to ${DOWNLOADED_AAC}"
rclone copyto "${RCLONE_REMOTE}/${LATEST_REMOTE_AAC}" "${DOWNLOADED_AAC}" -P

if [[ ! -f "${DOWNLOADED_AAC}" ]]; then
  log "ERROR: downloaded file not found: ${DOWNLOADED_AAC}"
  exit 1
fi

# -----------------------------
# 2) Rename downloaded file if it matches pattern
# -----------------------------
TARGET_AAC="${DOWNLOADED_AAC}"
BASE_AAC="${DOWNLOADED_AAC:t}"
if [[ "${BASE_AAC}" =~ ^craig_[^_]+_([0-9]{4}-[0-9]{1,2}-[0-9]{1,2})_11-(2[9]|3[0-9])-[0-9]{1,2}\.aac$ ]]; then
  date_part="${match[1]}"
  RENAMED_AAC="${LOCAL_DIR}/Lifehackerzy-DailyCoaching-${date_part}.aac"
  if [[ "${DOWNLOADED_AAC}" != "${RENAMED_AAC}" ]]; then
    log "Renaming: ${BASE_AAC} -> ${RENAMED_AAC:t}"
    mv -f -- "${DOWNLOADED_AAC}" "${RENAMED_AAC}"
    TARGET_AAC="${RENAMED_AAC}"
  fi
else
  log "Filename does not match rename pattern, keeping original: ${BASE_AAC}"
fi

# -----------------------------
# 3) Convert only selected AAC -> MP3 (small size)
# -----------------------------
LATEST_MP3="${MP3_DIR}/${TARGET_AAC:t:r}.mp3"
log "Converting: ${TARGET_AAC:t} -> ${LATEST_MP3:t}"
ffmpeg -y -hide_banner -loglevel error \
  -stats \
  -i "${TARGET_AAC}" \
  -ac 1 \
  -ar 16000 \
  -codec:a libmp3lame \
  -qscale:a 9 \
  "${LATEST_MP3}"

if [[ ! -f "${LATEST_MP3}" ]]; then
  log "ERROR: MP3 file was not created: ${LATEST_MP3}"
  exit 1
fi
log "MP3 selected for transcription: ${LATEST_MP3:t}"

# -----------------------------
# 4) Whisper transcription
# -----------------------------
log "Sending MP3 to OpenAI transcription API."
WHISPER_JSON_FILE="${LOCAL_DIR}/_whisper_response.json"
WHISPER_HTTP_CODE="$(curl -sS -o "${WHISPER_JSON_FILE}" -w "%{http_code}" -X POST "https://api.openai.com/v1/audio/transcriptions" \
  -H "Authorization: Bearer ${OPENAI_API_KEY}" \
  -F file=@"${LATEST_MP3}" \
  -F model=whisper-1)"

if [[ "${WHISPER_HTTP_CODE}" -lt 200 || "${WHISPER_HTTP_CODE}" -ge 300 ]]; then
  log "ERROR: Whisper HTTP status ${WHISPER_HTTP_CODE}"
  log "Whisper raw response: $(cat "${WHISPER_JSON_FILE}")"
  exit 1
fi

if ! jq -e . "${WHISPER_JSON_FILE}" >/dev/null 2>&1; then
  log "ERROR: Whisper returned non-JSON response."
  log "Whisper raw response: $(cat "${WHISPER_JSON_FILE}")"
  exit 1
fi

TRANSCRIPT_TEXT="$(jq -r '.text // empty' "${WHISPER_JSON_FILE}")"
if [[ -z "${TRANSCRIPT_TEXT}" ]]; then
  log "ERROR: transcription is empty."
  log "Whisper raw response: $(cat "${WHISPER_JSON_FILE}")"
  exit 1
fi
TRANSCRIPT_TEXT_CLEAN="${TRANSCRIPT_TEXT}"
log "Transcription received."

TRANSCRIPT_FILE="${TRANSCRIPTS_DIR}/${TARGET_AAC:t:r}.txt"
print -- "${TRANSCRIPT_TEXT_CLEAN}" >| "${TRANSCRIPT_FILE}"
log "Transcript saved: ${TRANSCRIPT_FILE}"

# -----------------------------
# 5) Generate article with Chat Completions
# -----------------------------
log "Generating summary article with ChatGPT."
CHATGPT_PAYLOAD="$(jq -n \
  --arg model "${CHATGPT_MODEL}" \
  --arg system "${CHATGPT_PROMPT}\n\n${CHATGPT_FORMAT_REQUIREMENTS}" \
  --arg user "${TRANSCRIPT_TEXT_CLEAN}" \
  '{
    model: $model,
    messages: [
      {role: "system", content: $system},
      {role: "user", content: $user}
    ]
  }')"

CHATGPT_JSON_FILE="${LOCAL_DIR}/_chatgpt_response.json"
CHATGPT_HTTP_CODE="$(curl -sS -o "${CHATGPT_JSON_FILE}" -w "%{http_code}" -X POST "https://api.openai.com/v1/chat/completions" \
  -H "Authorization: Bearer ${OPENAI_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "${CHATGPT_PAYLOAD}")"

if [[ "${CHATGPT_HTTP_CODE}" -lt 200 || "${CHATGPT_HTTP_CODE}" -ge 300 ]]; then
  log "ERROR: ChatGPT HTTP status ${CHATGPT_HTTP_CODE}"
  log "ChatGPT raw response: $(cat "${CHATGPT_JSON_FILE}")"
  exit 1
fi

if ! jq -e . "${CHATGPT_JSON_FILE}" >/dev/null 2>&1; then
  log "ERROR: ChatGPT returned non-JSON response."
  log "ChatGPT raw response: $(cat "${CHATGPT_JSON_FILE}")"
  exit 1
fi

ARTICLE_TEXT="$(jq -r '.choices[0].message.content // empty' "${CHATGPT_JSON_FILE}")"
if [[ -z "${ARTICLE_TEXT}" ]]; then
  log "ERROR: no article text returned by ChatGPT."
  log "ChatGPT raw response: $(cat "${CHATGPT_JSON_FILE}")"
  exit 1
fi

if (( ${#ARTICLE_TEXT} > MAX_DISCORD_CHARS )); then
  log "Article too long (${#ARTICLE_TEXT} chars). Requesting shorter single-message rewrite."
  SHORTEN_PAYLOAD="$(jq -n \
    --arg model "${CHATGPT_MODEL}" \
    --arg system "Skróć poniższy artykuł do maksymalnie ${MAX_DISCORD_CHARS} znaków. Zachowaj Markdown, konkret, sekcje i najważniejsze wnioski. Zwróć wyłącznie finalny tekst." \
    --arg user "${ARTICLE_TEXT}" \
    '{
      model: $model,
      messages: [
        {role: "system", content: $system},
        {role: "user", content: $user}
      ]
    }')"

  SHORTEN_JSON_FILE="${LOCAL_DIR}/_chatgpt_shorten_response.json"
  SHORTEN_HTTP_CODE="$(curl -sS -o "${SHORTEN_JSON_FILE}" -w "%{http_code}" -X POST "https://api.openai.com/v1/chat/completions" \
    -H "Authorization: Bearer ${OPENAI_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "${SHORTEN_PAYLOAD}")"

  if [[ "${SHORTEN_HTTP_CODE}" -ge 200 && "${SHORTEN_HTTP_CODE}" -lt 300 ]] && jq -e . "${SHORTEN_JSON_FILE}" >/dev/null 2>&1; then
    ARTICLE_TEXT="$(jq -r '.choices[0].message.content // empty' "${SHORTEN_JSON_FILE}")"
  fi

  if (( ${#ARTICLE_TEXT} > MAX_DISCORD_CHARS )); then
    log "Article still too long after rewrite; trimming to ${MAX_DISCORD_CHARS} chars."
    ARTICLE_TEXT="${ARTICLE_TEXT[1,$MAX_DISCORD_CHARS]}"
  fi
fi
log "Article generated."

# -----------------------------
# 6) Publish to Discord forum
# -----------------------------
THREAD_TITLE="Automated Transcript Article $(date '+%Y-%m-%d %H:%M')"
log "Publishing to Discord Forum: ${THREAD_TITLE}"

if [[ -z "${ARTICLE_TEXT}" ]]; then
  log "ERROR: article is empty before Discord publish."
  exit 1
fi

CREATE_THREAD_PAYLOAD="$(jq -n \
  --arg name "${THREAD_TITLE}" \
  --arg content "${ARTICLE_TEXT}" \
  '{
    name: $name,
    auto_archive_duration: 1440,
    message: { content: $content }
  }')"

DISCORD_CREATE_JSON_FILE="${LOCAL_DIR}/_discord_create_response.json"
DISCORD_CREATE_HTTP_CODE="$(curl -sS -o "${DISCORD_CREATE_JSON_FILE}" -w "%{http_code}" -X POST "https://discord.com/api/v10/channels/${DISCORD_FORUM_CHANNEL_ID}/threads" \
  -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${CREATE_THREAD_PAYLOAD}")"

if [[ "${DISCORD_CREATE_HTTP_CODE}" -lt 200 || "${DISCORD_CREATE_HTTP_CODE}" -ge 300 ]]; then
  log "ERROR: Discord thread create HTTP status ${DISCORD_CREATE_HTTP_CODE}"
  log "Discord raw response: $(cat "${DISCORD_CREATE_JSON_FILE}")"
  exit 1
fi

THREAD_ID="$(jq -r '.id // empty' "${DISCORD_CREATE_JSON_FILE}")"
if [[ -z "${THREAD_ID}" ]]; then
  log "ERROR: failed to create Discord forum thread."
  log "Discord raw response: $(cat "${DISCORD_CREATE_JSON_FILE}")"
  exit 1
fi
log "Discord thread created: ${THREAD_ID}"

FOLLOWUP_TEXT="Następny <#${NEXT_DAILY_CHANNEL_ID}> odbędzie się jak zwykle jutro o 12:34"
FOLLOWUP_PAYLOAD="$(jq -n --arg content "${FOLLOWUP_TEXT}" '{content: $content}')"
FOLLOWUP_HTTP_CODE="$(curl -sS -o /dev/null -w "%{http_code}" -X POST "https://discord.com/api/v10/channels/${THREAD_ID}/messages" \
  -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${FOLLOWUP_PAYLOAD}")"
if [[ "${FOLLOWUP_HTTP_CODE}" -lt 200 || "${FOLLOWUP_HTTP_CODE}" -ge 300 ]]; then
  log "ERROR: follow-up message failed with HTTP ${FOLLOWUP_HTTP_CODE}"
  exit 1
fi

log "Article published successfully."
log "Script completed successfully."
